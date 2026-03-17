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

  bool _hasPermission = false;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _checkCameraPermission();
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
  Widget build(BuildContext context) {
    if (!_hasPermission) {
      return const Scaffold(
        body: Center(child: Text("Camera permission is required for AR.")),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('AR Depth Utility')),
      body: Stack(
        children: [
          // 1. The Native AR View
          const AndroidView(
            viewType: 'depth_ar_view',
            creationParamsCodec: StandardMessageCodec(),
          ),

          // 2. UI Overlay for Capture
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 50.0),
              child: FloatingActionButton.extended(
                onPressed: _isProcessing ? null : _captureAndReturn,
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
