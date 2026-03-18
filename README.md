# Flutter Measure Anything App

A Flutter application that leverages the **Segment Anything Model (EdgeTAM)** and **ARCore** raw depth data to interactively segment objects and calculate their precise real-world dimensions. With integrated ARCore capabilities, this app natively captures and processes multi-layer `.tiff` files containing RGB imagery, 16-bit depth maps, confidence maps, and camera intrinsics all in one seamless workflow.

## 🌟 Features

- **Integrated AR Capture:** Built-in native Android ARCore integration captures high-fidelity 16-bit raw depth maps and 8-bit confidence maps directly within the app, removing the need for external tools.
- **Interactive Segmentation:** Add positive (green) and negative (red) reference points to guide the EdgeTAM (Segment Anything 2) segmentation model.
- **Rich TIFF Parsing:** Automatically extracts depth data, confidence maps, and EXIF metadata (Tag 270) containing the camera's focal length and principal points (`fx`, `fy`, `cx`, `cy`).
- **Real-World Measurements:** Computes the physical area (cm²), major axis (cm), and minor axis (cm) of segmented objects using Principal Component Analysis (PCA).
- **Visual Measurement Overlay:** Dynamically renders the calculated Major (orange) and Minor (cyan) PCA axes directly onto the 2D image, providing immediate visual verification of the object's orientation and scale alongside the physical measurements.
- **Hardware-Backed Noise Filtering:** Automatically leverages ARCore's 8-bit confidence map to discard "flying pixels" and unstable depth readings from reflective or textureless surfaces, ensuring highly reliable 3D point cloud generation.
- **Advanced Mask Processing:** Refines segmentation masks using OpenCV morphology operations to fill holes, remove isolated pixels (islands), or isolate the largest contour.
- **High Performance:** Heavy image processing, contour detection, and depth projection are offloaded to background Isolates to ensure the UI remains smooth.
- **Export & Save:** Composites the final segmentation mask over the original RGB image and saves it directly to your device's gallery. Measurements are stored as **PNG text chunks** in the image's metadata.

## 📋 Prerequisites

To run this application, you will need the following:

1. **Hardware:**
    An ARCore-supported Android device. For the most accurate real-world measurements, a device equipped with a hardware Time-of-Flight (ToF) depth sensor is highly recommended.

2. **ONNX Models:**
    The app uses the EdgeTAM architecture for segmentation. You need to export the PyTorch models to ONNX format using the [edgetam_onnx_export.ipynb](https://github.com/IoT-gamer/segment-anything-dinov3-onnx/blob/main/notebooks/edgetam_onnx_export.ipynb) notebook found in the [Segment Anything DINOv3 ONNX](https://github.com/IoT-gamer/segment-anything-dinov3-onnx) repository.

## 🚀 Installation & Setup

1. **Clone the repository:**

    ```bash
    git clone https://github.com/IoT-gamer/flutter_measure_anything_app.git
    cd flutter_measure_anything_app
    ```

2. **Install dependencies:**

    ```bash
    flutter pub get
    ```

3. **Add the ONNX Models:**

    Place your exported ONNX models into the `assets/models/` directory. Ensure the filenames match the following paths exactly:
    - `assets/models/edgetam_encoder.onnx`
    - `assets/models/edgetam_decoder.onnx`

4. **Run the application:**
    ```bash
    flutter run
    ```

## 🧠 How it Works

**1. AR Depth Capture**
The user taps "Capture AR Depth", opening a native Android ARCore view. The app acquires a synchronized RGB frame, a 16-bit raw depth map, and an 8-bit confidence map, packing them alongside the camera's intrinsic parameters into a temporary multi-page TIFF file.

**2. Image Preprocessing & Encoding** Once the capture is returned to the segmentation screen, the app decodes the first frame (RGB) and scales it to 1024x1024. The image tensor is normalized and passed to `edgetam_encoder.onnx` to generate the image embeddings.

**3. Point Prompting & Decoding** When you tap the screen, the widget coordinates are mapped back to the model's 1024x1024 coordinate space. These point coordinates and their associated labels (1 for positive, 0 for negative) are passed to `edgetam_decoder.onnx` alongside the image embeddings.

**4. Mask Generation & Refinement**
The decoder outputs low-resolution masks and Intersection over Union (IoU) predictions. The app selects the mask with the highest IoU. If enabled, an Isolate applies OpenCV operations (`cv.morphologyEx` and `cv.findContours`) to clean up the mask (filling holes, removing islands, keeping the largest area) before resizing it back to the original image dimensions.

**5. Dimension Calculation** Once the mask is finalized, the measurement service calculates real-world dimensions by:
- Mapping the RGB mask pixels to the corresponding depth map pixels, accounting for any aspect ratio cropping (uniform scaling and offsets).
- Projecting the 2D pixel coordinates and depth (Z) values into a 3D point cloud using the camera's intrinsics.
- Calculating the area of each valid pixel patch and summing them for total Area (cm²).
- Applying Principal Component Analysis (PCA) to the 3D point cloud to determine the bounding box's Major and Minor axes, using the 2nd and 98th percentiles to filter out noise.
- Running a secondary 2D PCA on the mask's pixel coordinates to compute the rotation and centroid, allowing the app to accurately paint the orientation axes over the UI.

## 📝 Capture Best Practices & Notes

- **Resolution:** The resolution of the ARCore Raw Depth API depth map is typically 160x90 pixels, but can be higher, up to 640x480 pixels, on some devices. The exact resolution depends on the specific device and its hardware capabilities, such as the presence of a Time-of-Flight (ToF) sensor. *(Note: The app's measurement service automatically maps and scales this lower-resolution depth data to fit the high-resolution RGB image).*
- **Hardware Sensitivities:** Devices without a ToF sensor may produce less accurate depth data. 
- **Camera Movement:** Moving the camera significantly improves raw depth accuracy and quality in ARCore, especially on devices that do not have a dedicated hardware depth sensor. Move the phone in a slow, smooth arc (about 10–20 cm) around the object you are about to capture.
- **Optimal Range:** Stay within the optimal range for the Raw Depth API, typically between **0.5 meters and 5 meters**.
- **Material Limitations:** It is normal for some areas of the depth map to have invalid or missing depth values, especially in regions where the camera cannot accurately measure depth (e.g., reflective surfaces, transparent objects, or areas with insufficient texture). These invalid depth values are typically represented as zeros or very high values in the depth map. The app automatically filters out these noisy areas using the 8-bit confidence map to preserve measurement accuracy.

## 📄 LICENSE
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgements
* This project is heavily reliant on the research and models provided by the Meta AI Research team in their [EdgeTAM project](https://github.com/facebookresearch/EdgeTAM).
* Uses the [Android-TiffBitmapFactory deckerst Fork](https://github.com/deckerst/Android-TiffBitmapFactory) for multi-layer TIFF handling.