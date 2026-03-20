import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

class MeasurementResult {
  final double areaCm2;
  final double majorAxisCm;
  final double minorAxisCm;
  final Offset centerPixel;
  final double angleRadian;
  final double majorLengthPx;
  final double minorLengthPx;

  MeasurementResult({
    required this.areaCm2,
    required this.majorAxisCm,
    required this.minorAxisCm,
    required this.centerPixel,
    required this.angleRadian,
    required this.majorLengthPx,
    required this.minorLengthPx,
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

    List<List<double>> pointCloud = []; // Physical 3D points
    List<List<double>> pixelCloud = []; // Visual 2D points
    double totalAreaCm2 = 0.0;

    for (int y = 0; y < maskH; y++) {
      for (int x = 0; x < maskW; x++) {
        // Check mask (Green channel > 0)
        final pixel = maskImage.getPixel(x, y);

        if (pixel.g > 0 && pixel.a > 0) {
          // Save pixel coordinates for 2D PCA
          pixelCloud.add([x.toDouble(), y.toDouble()]);
          // Map RGB pixel to Depth domain using the UNIFORM scale and offset
          final double xInDepthDomain = (x * scaleUniform) - xOffset;
          final double yInDepthDomain = (y * scaleUniform) - yOffset;

          // Round to get the nearest depth pixel index
          int dx = xInDepthDomain.round();
          int dy = yInDepthDomain.round();

          // Skip pixels that fall outside the depth map's cropped field of view
          if (dx < 0 || dx >= depthWidth || dy < 0 || dy >= depthHeight) {
            continue;
          }

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
      return MeasurementResult(
        areaCm2: 0,
        majorAxisCm: 0,
        minorAxisCm: 0,
        centerPixel: Offset.zero,
        angleRadian: 0,
        majorLengthPx: 0,
        minorLengthPx: 0,
      );
    }

    // Calculate Physical Axes (cm)
    final physicalAxes = _calculatePCA(pointCloud);
    // Calculate Visual Axes (pixels)
    final visualAxes = _calculatePCA(pixelCloud);

    // Apply the 3D tilt correction to the flattened 2D area
    double correctedAreaCm2 = totalAreaCm2 * physicalAxes.tiltRatio;

    return MeasurementResult(
      areaCm2: correctedAreaCm2,
      majorAxisCm: physicalAxes.major,
      minorAxisCm: physicalAxes.minor,
      centerPixel: Offset(visualAxes.cx, visualAxes.cy),
      angleRadian: visualAxes.theta,
      majorLengthPx: visualAxes.major,
      minorLengthPx: visualAxes.minor,
    );
  }

  /// Calculates the Oriented Bounding Box (OBB) using PCA angle
  static ({
    double major,
    double minor,
    double cx,
    double cy,
    double theta,
    double tiltRatio,
  })
  _calculatePCA(List<List<double>> points) {
    int n = points.length;
    if (n < 2) {
      return (
        major: 0.0,
        minor: 0.0,
        cx: 0.0,
        cy: 0.0,
        theta: 0.0,
        tiltRatio: 1.0,
      );
    }

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

    // Calculate Rotation Angle (Theta)
    double theta = 0.5 * atan2(2 * xy, xx - yy);
    final double cosT = cos(theta);
    final double sinT = sin(theta);

    List<({double proj, List<double> point})> projMajor = [];
    List<({double proj, List<double> point})> projMinor = [];

    for (var p in points) {
      double dx = p[0] - meanX;
      double dy = p[1] - meanY;
      projMajor.add((proj: dx * cosT + dy * sinT, point: p));
      projMinor.add((proj: -dx * sinT + dy * cosT, point: p));
    }

    projMajor.sort((a, b) => a.proj.compareTo(b.proj));
    projMinor.sort((a, b) => a.proj.compareTo(b.proj));

    int minIdx = (n * 0.02).floor().clamp(0, n - 1);
    int maxIdx = (n * 0.98).floor().clamp(0, n - 1);

    // --- Measure strictly along the axis line ---
    double getAxisLength(List<({double proj, List<double> point})> sortedProj) {
      // Get the flat 1D distance strictly along the projected axis
      double flatDist = sortedProj[maxIdx].proj - sortedProj[minIdx].proj;

      // Get the Z (depth) difference between those exact two points
      double dz = 0.0;
      if (sortedProj[maxIdx].point.length > 2 &&
          sortedProj[minIdx].point.length > 2) {
        dz = sortedProj[maxIdx].point[2] - sortedProj[minIdx].point[2];
      }

      // Calculate true length using the Pythagorean theorem (automatically handles 2D vs 3D)
      return sqrt(flatDist * flatDist + dz * dz);
    }

    double majorAxis = getAxisLength(projMajor);
    double minorAxis = getAxisLength(projMinor);

    // Calculate Area Tilt Correction
    double flatMajor = projMajor[maxIdx].proj - projMajor[minIdx].proj;
    double flatMinor = projMinor[maxIdx].proj - projMinor[minIdx].proj;

    double tiltRatio = (flatMajor * flatMinor > 0.01)
        ? (majorAxis * minorAxis) / (flatMajor * flatMinor)
        : 1.0;

    // Ensure Major is the larger one
    if (minorAxis > majorAxis) {
      final temp = majorAxis;
      majorAxis = minorAxis;
      minorAxis = temp;
      theta += (pi / 2);
    }

    return (
      major: majorAxis,
      minor: minorAxis,
      cx: meanX,
      cy: meanY,
      theta: theta,
      tiltRatio: tiltRatio,
    );
  }
}
