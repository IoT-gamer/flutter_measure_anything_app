import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

class MeasurementResult {
  final double areaCm2;
  final double majorAxisCm;
  final double minorAxisCm;

  MeasurementResult({
    required this.areaCm2,
    required this.majorAxisCm,
    required this.minorAxisCm,
  });

  @override
  String toString() {
    return 'Area: ${areaCm2.toStringAsFixed(1)} cm²\n'
        'Major Axis: ${majorAxisCm.toStringAsFixed(1)} cm\n'
        'Minor Axis: ${minorAxisCm.toStringAsFixed(1)} cm';
  }
}

class MeasurementService {
  static Future<MeasurementResult> calculateDimensions({
    required img.Image maskImage,
    required Uint16List depthMap,
    Uint8List? confidenceMap,
    required int depthWidth,
    required int depthHeight,
    required double fx,
    required double fy,
    required double cx,
    required double cy,
  }) async {
    final int maskW = maskImage.width;
    final int maskH = maskImage.height;

    // Calculate a uniform scale and offsets to handle center-cropping
    final double rgbAspect = maskW / maskH;
    final double depthAspect = depthWidth / depthHeight;

    double scaleUniform;
    double xOffset = 0.0;
    double yOffset = 0.0;

    if (rgbAspect > depthAspect) {
      // RGB is wider than Depth; Depth map is horizontally cropped
      scaleUniform = depthHeight / maskH;
      xOffset = ((maskW * scaleUniform) - depthWidth) / 2.0;
    } else {
      // Depth is wider than RGB; Depth map is vertically cropped (Standard ARCore behavior)
      scaleUniform = depthWidth / maskW;
      yOffset = ((maskH * scaleUniform) - depthHeight) / 2.0;
    }

    List<List<double>> pointCloud = [];
    double totalAreaCm2 = 0.0;

    for (int y = 0; y < maskH; y++) {
      for (int x = 0; x < maskW; x++) {
        // Check mask (Green channel > 0)
        final pixel = maskImage.getPixel(x, y);

        if (pixel.g > 0 && pixel.a > 0) {
          // Map RGB pixel to Depth domain using the UNIFORM scale and offset
          final double xInDepthDomain = (x * scaleUniform) - xOffset;
          final double yInDepthDomain = (y * scaleUniform) - yOffset;

          // Round to get the nearest depth pixel index
          int dx = xInDepthDomain.round();
          int dy = yInDepthDomain.round();

          // Skip pixels that fall outside the depth map's cropped field of view
          if (dx < 0 || dx >= depthWidth || dy < 0 || dy >= depthHeight)
            continue;

          final int depthIndex = dy * depthWidth + dx;
          if (depthIndex >= depthMap.length) continue;

          // Confidence Map Filtering
          if (confidenceMap != null) {
            // Read the 8-bit confidence score (0-255)
            final int confidence = confidenceMap[depthIndex];
            // Filter out points with low confidence (threshold of 190)
            if (confidence < 190) continue;
          }

          final int depthMm = depthMap[depthIndex];

          // Ignore invalid depth (0 = unknown, >10m = too far)
          if (depthMm <= 0 || depthMm > 10000) continue;

          final double zCm = depthMm / 10.0;

          // Project to 3D using the properly scaled floating-point coordinates
          final double xCm = (xInDepthDomain - cx) * zCm / fx;
          final double yCm = (yInDepthDomain - cy) * zCm / fy;

          pointCloud.add([xCm, yCm, zCm]);

          // Area of this specific RGB pixel at distance Z using the uniform scale
          final double patchWidth = (zCm / fx) * scaleUniform;
          final double patchHeight = (zCm / fy) * scaleUniform;

          totalAreaCm2 += (patchWidth * patchHeight);
        }
      }
    }

    if (pointCloud.isEmpty) {
      return MeasurementResult(areaCm2: 0, majorAxisCm: 0, minorAxisCm: 0);
    }

    // 4. Calculate Axes using PCA
    final axes = _calculatePCA(pointCloud);

    return MeasurementResult(
      areaCm2: totalAreaCm2,
      majorAxisCm: axes.major,
      minorAxisCm: axes.minor,
    );
  }

  /// Calculates the Oriented Bounding Box (OBB) using PCA angle
  static ({double major, double minor}) _calculatePCA(
    List<List<double>> points,
  ) {
    int n = points.length;
    if (n < 2) return (major: 0.0, minor: 0.0);

    // Calculate Centroid
    double sumX = 0, sumY = 0;
    for (var p in points) {
      sumX += p[0];
      sumY += p[1];
    }
    double meanX = sumX / n;
    double meanY = sumY / n;

    // Compute 2D Covariance Matrix terms
    double xx = 0, yy = 0, xy = 0;
    for (var p in points) {
      double dx = p[0] - meanX;
      double dy = p[1] - meanY;
      xx += dx * dx;
      yy += dy * dy;
      xy += dx * dy;
    }

    // Calculate Rotation Angle (Theta) of the Major Axis
    // Formula: 0.5 * atan2(2*xy, xx - yy)
    final double theta = 0.5 * atan2(2 * xy, xx - yy);
    final double cosT = cos(theta);
    final double sinT = sin(theta);

    // Project all points onto the new rotated axes (Major and Minor)
    // We want to find the physical extent (Max - Min) along these axes.
    List<double> projectedMajor = [];
    List<double> projectedMinor = [];

    for (var p in points) {
      // Center the point first
      double dx = p[0] - meanX;
      double dy = p[1] - meanY;

      // Rotate:
      // Major = x*cos + y*sin
      // Minor = -x*sin + y*cos
      projectedMajor.add(dx * cosT + dy * sinT);
      projectedMinor.add(-dx * sinT + dy * cosT);
    }

    // Calculate Range using Percentiles (Robust to outliers)
    // Using strict Min/Max can be ruined by one noisy pixel.
    // Using 2% and 98% is safer for depth maps.
    projectedMajor.sort();
    projectedMinor.sort();

    // Helper to get percentile value
    double getRange(List<double> sortedData) {
      if (sortedData.isEmpty) return 0.0;
      int minIdx = (n * 0.02).floor().clamp(0, n - 1); // 2nd percentile
      int maxIdx = (n * 0.98).floor().clamp(0, n - 1); // 98th percentile
      return sortedData[maxIdx] - sortedData[minIdx];
    }

    double majorAxis = getRange(projectedMajor);
    double minorAxis = getRange(projectedMinor);

    // Ensure Major is the larger one
    if (minorAxis > majorAxis) {
      final temp = majorAxis;
      majorAxis = minorAxis;
      minorAxis = temp;
    }

    return (major: majorAxis, minor: minorAxis);
  }
}
