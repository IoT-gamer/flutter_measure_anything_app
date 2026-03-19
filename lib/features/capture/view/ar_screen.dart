import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class ARScreen extends StatefulWidget {
  const ARScreen({super.key});

  @override
  State<ARScreen> createState() => _ARScreenState();
}

class _ARScreenState extends State<ARScreen> {
  // The channel name must match DepthView.kt exactly
  static const MethodChannel _channel = MethodChannel(
    'com.example.flutter_measure_anything_app/depth_ar_channel',
  );

  static const EventChannel _coverageChannel = EventChannel(
    'com.example.flutter_measure_anything_app/depth_coverage_channel',
  );

  bool _hasPermission = false;
  bool _isProcessing = false;

  double _depthCoverage = 0.0;
  StreamSubscription? _coverageSubscription;

  @override
  void initState() {
    super.initState();
    _checkCameraPermission();
  }

  void _startCoverageStream() {
    _coverageSubscription = _coverageChannel.receiveBroadcastStream().listen((
      event,
    ) {
      setState(() {
        _depthCoverage = event as double; // This will be 0.0 to 1.0
      });
    }, onError: (error) => debugPrint("Coverage Stream Error: $error"));
  }

  Future<void> _checkCameraPermission() async {
    var status = await Permission.camera.status;
    if (status.isGranted) {
      setState(() => _hasPermission = true);
    } else {
      status = await Permission.camera.request();
      setState(() => _hasPermission = status.isGranted);
    }
  }

  /// Triggers the native ARCore capture and returns the resulting TIFF File.
  Future<void> _captureAndReturn() async {
    setState(() => _isProcessing = true);

    try {
      final String? tempPath = await _channel.invokeMethod<String>(
        'captureTiff',
      );

      if (tempPath != null) {
        debugPrint("Temporary TIFF path: $tempPath"); //

        // Use standard File from dart:io to read the data
        final File file = File(tempPath);

        // Add a small delay to ensure the background IO thread on the
        // native side has fully closed the file stream.
        await Future.delayed(const Duration(milliseconds: 150)); //

        // Important: On some Android devices, the file sync isn't instant.
        // We check the length using dart:io.
        int length = await file.length();
        debugPrint("File length perceived by Flutter: $length bytes"); //

        if (length > 0) {
          //
          // INSTEAD OF SAVING: Return the file to the previous screen
          if (mounted) {
            Navigator.pop(context, file);
          }
        } else {
          _showSnackBar("Error: Captured file is empty.");
        }
      }
    } catch (e) {
      _showSnackBar("Error: $e");
    } finally {
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _coverageSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasPermission) {
      return const Scaffold(
        body: Center(child: Text("Camera permission is required for AR.")),
      );
    }

    // --- Determine UI states based on live coverage ---
    // Require at least 20% coverage to allow a capture
    final bool canCapture = _depthCoverage >= 0.20;

    Color indicatorColor;
    String indicatorText;

    // debugPrint("Depth Coverage: $_depthCoverage");

    if (_depthCoverage < 0.20) {
      indicatorColor = Colors.redAccent;
      indicatorText = "Poor Depth - Move closer or pan slowly";
    } else if (_depthCoverage < 0.50) {
      indicatorColor = Colors.orangeAccent;
      indicatorText = "Fair Depth - Keep scanning object";
    } else {
      indicatorColor = Colors.greenAccent;
      indicatorText = "Good Depth - Ready to capture";
    }

    return Scaffold(
      appBar: AppBar(title: const Text('AR Depth Utility')),
      body: Stack(
        children: [
          // The Native AR View
          AndroidView(
            viewType: 'depth_ar_view',
            creationParamsCodec: const StandardMessageCodec(),
            //  Wait for the native view to be built before listening
            onPlatformViewCreated: (int id) {
              _startCoverageStream();
            },
          ),

          // Depth Quality HUD Overlay
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.black54, // Semi-transparent background
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    indicatorText,
                    style: TextStyle(
                      color: indicatorColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Animated progress bar mapped to the 0.0 - 1.0 coverage float
                  LinearProgressIndicator(
                    value: _depthCoverage,
                    backgroundColor: Colors.grey[800],
                    valueColor: AlwaysStoppedAnimation<Color>(indicatorColor),
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ],
              ),
            ),
          ),

          // UI Overlay for Capture
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 50.0),
              child: FloatingActionButton.extended(
                // Disable button if processing OR if depth coverage is too low
                onPressed: (_isProcessing || !canCapture)
                    ? null
                    : _captureAndReturn,
                backgroundColor: canCapture ? null : Colors.grey.shade400,
                label: _isProcessing
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Capture 16-bit TIFF'),
                icon: const Icon(Icons.camera),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Simple proxy for file operations if not using dart:io directly
class SystemFileProxy {
  final String path;
  SystemFileProxy(this.path);
  Future<Uint8List> readAsBytes() async {
    // Standard implementation: return File(path).readAsBytesSync();
    return Uint8List(0); // Placeholder
  }
}
