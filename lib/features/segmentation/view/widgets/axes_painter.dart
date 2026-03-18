import 'dart:math';
import 'package:flutter/material.dart';
import '../../services/measurement_service.dart';

class AxesPainter extends CustomPainter {
  final MeasurementResult measurement;
  final Size originalImageSize;

  AxesPainter(this.measurement, this.originalImageSize);

  @override
  void paint(Canvas canvas, Size size) {
    if (originalImageSize.isEmpty || measurement.majorLengthPx == 0) return;

    final fittedSizes = applyBoxFit(BoxFit.contain, originalImageSize, size);
    final Size destSize = fittedSizes.destination;
    final double dx = (size.width - destSize.width) / 2;
    final double dy = (size.height - destSize.height) / 2;
    final Rect destRect = Rect.fromLTWH(
      dx,
      dy,
      destSize.width,
      destSize.height,
    );

    // Scale factors to convert from original image pixels to widget pixels
    final double scaleX = destRect.width / originalImageSize.width;
    final double scaleY = destRect.height / originalImageSize.height;

    // Helper to map an original pixel Offset to the widget Canvas Offset
    Offset mapToWidget(double imgX, double imgY) {
      return Offset(
        (imgX * scaleX) + destRect.left,
        (imgY * scaleY) + destRect.top,
      );
    }

    final double cx = measurement.centerPixel.dx;
    final double cy = measurement.centerPixel.dy;
    final double theta = measurement.angleRadian;

    final double cosT = cos(theta);
    final double sinT = sin(theta);

    // --- Calculate Major Axis Endpoints ---
    final double halfMajor = measurement.majorLengthPx / 2;
    final Offset majorStartImg = Offset(
      cx - halfMajor * cosT,
      cy - halfMajor * sinT,
    );
    final Offset majorEndImg = Offset(
      cx + halfMajor * cosT,
      cy + halfMajor * sinT,
    );

    // --- Calculate Minor Axis Endpoints ---
    final double halfMinor = measurement.minorLengthPx / 2;
    // Perpendicular angle: (-sinT, cosT)
    final Offset minorStartImg = Offset(
      cx - halfMinor * (-sinT),
      cy - halfMinor * cosT,
    );
    final Offset minorEndImg = Offset(
      cx + halfMinor * (-sinT),
      cy + halfMinor * cosT,
    );

    // Draw Major Axis (Orange)
    final Paint majorPaint = Paint()
      ..color = Colors.orangeAccent
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      mapToWidget(majorStartImg.dx, majorStartImg.dy),
      mapToWidget(majorEndImg.dx, majorEndImg.dy),
      majorPaint,
    );

    // Draw Minor Axis (Cyan)
    final Paint minorPaint = Paint()
      ..color = Colors.cyanAccent
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    canvas.drawLine(
      mapToWidget(minorStartImg.dx, minorStartImg.dy),
      mapToWidget(minorEndImg.dx, minorEndImg.dy),
      minorPaint,
    );
  }

  @override
  bool shouldRepaint(covariant AxesPainter oldDelegate) {
    return oldDelegate.measurement != measurement ||
        oldDelegate.originalImageSize != originalImageSize;
  }
}
