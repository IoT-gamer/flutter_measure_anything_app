package com.example.flutter_measure_anything_app

import kotlinx.coroutines.*
import com.google.ar.core.Frame
import com.google.ar.core.exceptions.NotYetAvailableException
import java.nio.ByteBuffer

class DepthCoverageAnalyzer {

    // Throttle calculation to 5 times a second (200ms)
    private val calculationIntervalMs = 200L
    private var lastCalculationTime = 0L

    // Keep track of the coroutine job so we don't stack them
    private var analysisJob: Job? = null
    
    // Custom scope for background processing
    private val analyzerScope = CoroutineScope(Dispatchers.Default)

    /**
     * Call this inside your AR Session's onUpdate or onDrawFrame
     * @param frame The current ARCore Frame
     * @param onCoverageResult Callback to send the float percentage back to Flutter
     */
    fun analyzeFrame(frame: Frame, onCoverageResult: (Float) -> Unit) {
        val currentTime = System.currentTimeMillis()

        // Skip frames: Only run every 200ms
        if (currentTime - lastCalculationTime < calculationIntervalMs) {
            return
        }

        // Prevent overlapping jobs: If the last one is still running, skip this frame
        if (analysisJob?.isActive == true) {
            return
        }

        lastCalculationTime = currentTime

        // Launch Coroutine on Default (CPU) dispatcher
        analysisJob = analyzerScope.launch {
            try {
                // Acquire the 8-bit confidence map
                val confidenceImage = frame.acquireRawDepthConfidenceImage()
                
                confidenceImage.use { image ->
                    val planes = image.planes
                    if (planes.isNotEmpty()) {
                        val buffer: ByteBuffer = planes[0].buffer
                        val pixelStride = planes[0].pixelStride
                        val rowStride = planes[0].rowStride
                        val width = image.width
                        val height = image.height

                        var validPixels = 0
                        var totalCheckedPixels = 0

                        // 4. Downsample: Check every 2nd row and 2nd column
                        val step = 2 

                        for (y in 0 until height step step) {
                            for (x in 0 until width step step) {
                                val index = y * rowStride + x * pixelStride
                                // Read the 8-bit unsigned value
                                val confidence = buffer.get(index).toInt() and 0xFF
                                
                                if (confidence >= 190) {
                                    validPixels++
                                }
                                totalCheckedPixels++
                            }
                        }

                        // Calculate percentage (0.0 to 1.0)
                        val coveragePercentage = if (totalCheckedPixels > 0) {
                            validPixels.toFloat() / totalCheckedPixels.toFloat()
                        } else {
                            0f
                        }

                        // Switch back to Main thread if you are immediately sinking this to Flutter
                        withContext(Dispatchers.Main) {
                            onCoverageResult(coveragePercentage)
                        }
                    }
                }
            } catch (e: NotYetAvailableException) {
                // Perfectly normal in ARCore when tracking is initializing
            } catch (e: Exception) {
                // Handle other potential issues
                e.printStackTrace()
            }
        }
    }
    
    // Don't forget to cancel the scope when the AR view is destroyed
    fun close() {
        analyzerScope.cancel()
    }
}