package com.example.flutter_measure_anything_app

import android.app.Activity
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraCharacteristics
import android.opengl.GLES20
import android.opengl.GLSurfaceView
import android.util.Log
import android.view.Surface
import android.view.View
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import com.google.ar.core.Config
import com.google.ar.core.Session
import com.google.ar.core.examples.java.common.helpers.DisplayRotationHelper
import com.google.ar.core.examples.java.common.rendering.BackgroundRenderer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.beyka.tiffbitmapfactory.TiffSaver
import org.beyka.tiffbitmapfactory.CompressionScheme
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteOrder

class DepthView(
    private val activity: Activity,
    private val context: Context,
    messenger: BinaryMessenger,
    id: Int,
    private val lifecycle: Lifecycle
) : PlatformView, DefaultLifecycleObserver, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, GLSurfaceView.Renderer {

    private val glSurfaceView: GLSurfaceView
    private val displayRotationHelper: DisplayRotationHelper
    private val backgroundRenderer = BackgroundRenderer()
    private var session: Session? = null
    private val mainScope = CoroutineScope(Dispatchers.Main)
    private val depthCoverageAnalyzer = DepthCoverageAnalyzer()
    private var eventSink: EventChannel.EventSink? = null

    init {
        glSurfaceView = GLSurfaceView(context).apply {
            setEGLContextClientVersion(2)
            setRenderer(this@DepthView)
            renderMode = GLSurfaceView.RENDERMODE_CONTINUOUSLY
        }
        displayRotationHelper = DisplayRotationHelper(context)

        // Setup MethodChannel
        val methodChannel = MethodChannel(messenger, "com.example.flutter_measure_anything_app/depth_ar_channel")
        methodChannel.setMethodCallHandler(this)

        // Setup EventChannel for the coverage stream
        val eventChannel = EventChannel(messenger, "com.example.flutter_measure_anything_app/depth_coverage_channel")
        eventChannel.setStreamHandler(this)

        lifecycle.addObserver(this)
    }

    // Implement EventChannel.StreamHandler methods
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun getView(): View = glSurfaceView

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "captureTiff") {
            captureTiffData(result)
        } else {
            result.notImplemented()
        }
    }

    private fun captureTiffData(result: MethodChannel.Result) {
        val currentSession = session ?: return
        
        // We stay on the GL thread just long enough to acquire the images
        glSurfaceView.queueEvent {
            try {
                val frame = currentSession.update()
                
                // Acquire all images
                val depthImage = frame.acquireRawDepthImage16Bits()
                val confidenceImage = frame.acquireRawDepthConfidenceImage()
                val cameraImage = frame.acquireCameraImage()
                
                // Extract data to Bitmaps/Arrays
                val depthShorts = extract16BitDepth(depthImage)
                val rgbBitmap = imageToBitmap(cameraImage)
                
                // Convert Confidence to Bitmap
                val confidenceBitmap = confidenceToBitmap(confidenceImage)

                val depthWidth = depthImage.width
                val depthHeight = depthImage.height
                
                // Get intrinsics from the high-res camera texture
                val intrinsics = frame.camera.textureIntrinsics
                val textureDims = intrinsics.imageDimensions // [width, height] of the RGB stream
                
                // Calculate scaling factors to map intrinsics to the low-res depth map
                // We cast to Float to ensure floating point division
                val scaleW = depthWidth.toFloat() / textureDims[0].toFloat()
                val scaleH = depthHeight.toFloat() / textureDims[1].toFloat()

                // Scale the focal length (fx, fy) and principal point (cx, cy)
                val fx = intrinsics.focalLength[0] * scaleW
                val fy = intrinsics.focalLength[1] * scaleH
                val cx = intrinsics.principalPoint[0] * scaleW
                val cy = intrinsics.principalPoint[1] * scaleH

                // --- Calculate exact camera sensor rotation offset ---
                var imageRotation = 90 // Default fallback
                try {
                    val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
                    val cameraId = currentSession.cameraConfig.cameraId
                    val characteristics = cameraManager.getCameraCharacteristics(cameraId)
                    val sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
                    
                    @Suppress("DEPRECATION")
                    val displayRotation = activity.windowManager.defaultDisplay.rotation
                    val surfaceRotation = when (displayRotation) {
                        Surface.ROTATION_0 -> 0
                        Surface.ROTATION_90 -> 90
                        Surface.ROTATION_180 -> 180
                        Surface.ROTATION_270 -> 270
                        else -> 0
                    }
                    // Calculate the offset required to display the image upright
                    imageRotation = (sensorOrientation - surfaceRotation + 360) % 360
                } catch (e: Exception) {
                    Log.e("DepthView", "Could not determine sensor orientation", e)
                }                

                // Save the SCALED values into metadata
                val metadata = "fx:$fx,fy:$fy,cx:$cx,cy:$cy"

                // Close native images immediately to free up ARCore buffers 
                depthImage.close()
                confidenceImage.close()
                cameraImage.close()

                // Switch to a background thread for heavy I/O and TIFF encoding
                CoroutineScope(Dispatchers.IO).launch {
                    try {
                        val file = File(context.cacheDir, "capture_${System.currentTimeMillis()}.tiff")
                        val options = TiffSaver.SaveOptions().apply {
                            author = "ARCore Utility"
                            imageDescription = metadata
                            compressionScheme = CompressionScheme.LZW 
                        }

                        // Perform the heavy saving operations on the IO thread

                        // Page 0: RGB
                        TiffSaver.saveBitmap(file.absolutePath, rgbBitmap, options)
                        
                        // Page 1: Depth
                        val depthBitmap = packDepthIntoBitmap(depthShorts, depthWidth, depthHeight)
                        val appendSuccess = TiffSaver.appendBitmap(file.absolutePath, depthBitmap, options)

                        // Page 2: Confidence
                        TiffSaver.appendBitmap(file.absolutePath, confidenceBitmap, options)

                        val finalSize = file.length()
                        
                        // Return result to Flutter on the Main thread
                        mainScope.launch {
                            if (appendSuccess && finalSize > 0) {
                                result.success(file.absolutePath) 
                            } else {
                                result.error("SAVE_FAILED", "File is empty or append failed", null) 
                            }
                        }
                    } catch (e: Exception) {
                        mainScope.launch { result.error("IO_ERROR", e.message, null) }
                    }
                }
            } catch (e: Exception) {
                mainScope.launch { result.error("CAPTURE_FAILED", e.message, null)  }
            }
        }
    }

    private fun extract16BitDepth(image: android.media.Image): ShortArray {
        // Plane 0 contains the depth data in millimeters as 16-bit integers
        val buffer = image.planes[0].buffer.order(ByteOrder.LITTLE_ENDIAN)
        val shortArray = ShortArray(buffer.remaining() / 2)
        buffer.asShortBuffer().get(shortArray)
        return shortArray
    }

    private fun imageToBitmap(image: android.media.Image): Bitmap {
        val planes = image.planes
        val yBuffer = planes[0].buffer
        val uBuffer = planes[1].buffer
        val vBuffer = planes[2].buffer

        val ySize = yBuffer.remaining()
        val uSize = uBuffer.remaining()
        val vSize = vBuffer.remaining()

        val nv21 = ByteArray(ySize + uSize + vSize)

        // Copy Y plane
        yBuffer.get(nv21, 0, ySize)

        // Interleave U and V planes for NV21 format (V, U, V, U...)
        // This format is required by YuvImage to prevent the green tint
        vBuffer.get(nv21, ySize, vSize)
        uBuffer.get(nv21, ySize + vSize, uSize)

        val yuvImage = YuvImage(nv21, ImageFormat.NV21, image.width, image.height, null)
        val out = ByteArrayOutputStream()
        
        // Compress to JPEG to handle the YUV to RGB conversion natively
        yuvImage.compressToJpeg(Rect(0, 0, image.width, image.height), 100, out)
        
        // Use toByteArray() to get the exact compressed data size
        val compressedBytes = out.toByteArray()
        
        // Pass the exact length of the compressed array
        return BitmapFactory.decodeByteArray(compressedBytes, 0, compressedBytes.size)
    }

    private fun packDepthIntoBitmap(shorts: ShortArray, w: Int, h: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(w * h)
        for (i in shorts.indices) {
            val depth = shorts[i].toInt() and 0xFFFF
            val r = (depth shr 8) and 0xFF
            val g = depth and 0xFF
            pixels[i] = (0xFF shl 24) or (r shl 16) or (g shl 8)
        }
        bitmap.setPixels(pixels, 0, w, 0, 0, w, h)
        return bitmap
    }

    private fun confidenceToBitmap(image: android.media.Image): Bitmap {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val width = image.width
        val height = image.height
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        
        // Create an empty bitmap
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        
        // Prepare pixel array
        val pixels = IntArray(width * height)
        
        for (y in 0 until height) {
            for (x in 0 until width) {
                // Calculate the offset in the byte buffer
                val offset = y * rowStride + x * pixelStride
                
                // Read the 8-bit confidence value (0-255)
                // We mask with 0xFF to treat the signed byte as unsigned
                val confidence = buffer.get(offset).toInt() and 0xFF
                
                // Pack into ARGB (Grayscale)
                // Alpha = 255 (Opaque), R=G=B=confidence
                pixels[y * width + x] = (0xFF shl 24) or 
                                      (confidence shl 16) or 
                                      (confidence shl 8) or 
                                      confidence
            }
        }
        
        bitmap.setPixels(pixels, 0, width, 0, 0, width, height)
        return bitmap
    }

    override fun onSurfaceCreated(gl: javax.microedition.khronos.opengles.GL10?, config: javax.microedition.khronos.egl.EGLConfig?) {
        backgroundRenderer.createOnGlThread(context)
        
        // Safety check for camera permission on the native side
        try {
            session = Session(context).apply {
                val arConfig = Config(this)

                arConfig.focusMode = Config.FocusMode.AUTO

                if (isDepthModeSupported(Config.DepthMode.AUTOMATIC)) {
                    arConfig.depthMode = Config.DepthMode.AUTOMATIC 
                }
                configure(arConfig)
                resume() 
            }
        } catch (e: Exception) {
            Log.e("DepthView", "ARCore session failed to initialize: ${e.message}")
            // Inform Flutter via a separate MethodChannel if needed
        }
    }

    override fun onDrawFrame(gl: javax.microedition.khronos.opengles.GL10?) {
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT or GLES20.GL_DEPTH_BUFFER_BIT)
        session?.let {
            displayRotationHelper.updateSessionIfNeeded(it)
            it.setCameraTextureName(backgroundRenderer.textureId)
            // Extract the frame into a variable so we can pass it to the analyzer
            val frame = it.update()

            // Draw the AR background
            backgroundRenderer.draw(frame)

            // Feed the frame to the analyzer
            if (eventSink != null) {
                depthCoverageAnalyzer.analyzeFrame(frame) { percentage ->
                    // This callback runs on the Main thread, safe to sink to Flutter
                    eventSink?.success(percentage)
                }
            }
        }
    }

    override fun onSurfaceChanged(gl: javax.microedition.khronos.opengles.GL10?, width: Int, height: Int) {
        displayRotationHelper.onSurfaceChanged(width, height)
        GLES20.glViewport(0, 0, width, height)
    }

    override fun dispose() {
        depthCoverageAnalyzer.close()
        eventSink = null
        
        session?.close()
        session = null
    }
}