import 'dart:io';
import 'dart:typed_data';
import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/segmentation_models.dart';
import '../services/image_processing.dart';
import '../services/measurement_service.dart';

part 'segmentation_state.dart';

class SegmentationCubit extends Cubit<SegmentationState> {
  static const _encoderAssetPath = 'assets/models/edgetam_encoder.onnx';
  static const _decoderAssetPath = 'assets/models/edgetam_decoder.onnx';
  static const _modelInputSize = 1024;

  OrtSession? _encoderSession;
  OrtSession? _decoderSession;

  SegmentationCubit() : super(const SegmentationState()) {
    _initOrtSessions();
  }

  Future<void> _initOrtSessions() async {
    emit(state.copyWith(status: SegmentationStatus.loadingModels));
    try {
      _encoderSession = await OnnxRuntime().createSessionFromAsset(
        _encoderAssetPath,
      );
      _decoderSession = await OnnxRuntime().createSessionFromAsset(
        _decoderAssetPath,
      );
      emit(state.copyWith(status: SegmentationStatus.modelsReady));
    } catch (e) {
      emit(
        state.copyWith(
          status: SegmentationStatus.failure,
          errorMessage: 'Failed to load models: $e',
        ),
      );
    }
  }

  // segmentation_cubit.dart

  Future<void> pickTiffFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );

      if (result != null && result.files.single.path != null) {
        final String path = result.files.single.path!;

        // Manual Extension Filter
        final String extension = path.split('.').last.toLowerCase();
        if (extension != 'tiff' && extension != 'tif') {
          emit(
            state.copyWith(
              errorMessage: "Please select a valid .tiff or .tif file.",
            ),
          );
          return;
        }

        final file = File(path);
        // Reading bytes might be slow, so we emit a loading state
        emit(state.copyWith(status: SegmentationStatus.processing));

        final bytes = await file.readAsBytes();
        await loadTiffData(bytes, file);
      }
    } catch (e) {
      debugPrint("Error picking file: $e");
      emit(
        state.copyWith(
          status: SegmentationStatus.failure,
          errorMessage: "Failed to pick file: $e",
        ),
      );
    }
  }

  Future<void> loadTiffData(Uint8List bytes, File file) async {
    // Decode the TIFF
    final image = img.decodeTiff(bytes);
    if (image == null) {
      debugPrint("Failed to decode TIFF file.");
      return;
    }

    // Extract Intrinsics (Tag 270)
    String? metadataString;
    if (image.exif.hasTag(270)) {
      final tag = image.exif.getTag(270);

      // Get the raw string (which includes "IfdValue(...)")
      metadataString = tag.toString();

      // Clean it: Extract the part after "value: "
      if (metadataString.startsWith('IfdValue')) {
        // Example format: "IfdValue(type: ASCII, count: 30, value: fx:500.1,fy:500.1...)"
        if (metadataString.contains('value: ')) {
          metadataString = metadataString.split('value: ').last;

          // Remove the trailing closing parenthesis ')' added by toString()
          if (metadataString.endsWith(')')) {
            metadataString = metadataString.substring(
              0,
              metadataString.length - 1,
            );
          }
        }
      }
      debugPrint("Cleaned Metadata: $metadataString");
    }

    // Parse if we found data
    if (metadataString != null && metadataString.isNotEmpty) {
      _parseIntrinsics(metadataString);
    }

    // Process Layers
    Uint16List? depthMap;
    Uint8List? confidenceMap;
    int? dW, dH; // Variables to hold dimensions

    // We must extract depth BEFORE we modify the image structure
    if (image.frames.length >= 2) {
      // The second frame (index 1) is the Depth Map
      final depthFrame = image.frames[1];
      dW = depthFrame.width; // Capture width
      dH = depthFrame.height; // Capture height
      depthMap = _reconstructDepthMap(depthFrame);
    }

    if (image.frames.length >= 3) {
      // Frame 2: Confidence
      // It's already 8-bit grayscale, so we can use luminance or red channel
      final confFrame = image.frames[2];
      // Flatten to simple list of bytes
      confidenceMap = confFrame.getBytes(order: img.ChannelOrder.red);
    }

    // The 'image' object returned by decodeTiff contains a list of ALL frames.
    // Even if we only want the first one, encodePng will see the list and
    // create an Animated PNG (APNG), causing the flickering.
    // We explicitly clear the list to force a static, single-frame PNG.
    image.frames.clear();

    // Now this encodes strictly the first frame (RGB)
    final singleFramePngBytes = img.encodePng(image);

    emit(
      state.copyWith(
        status: SegmentationStatus.success,
        imageFile: file,
        originalImage: image, // This is now a clean single-frame image
        displayImageData: singleFramePngBytes,
        maskImageData: null,
        clearMask: true,
        points: [],
        depthMap: depthMap, // Store the depth we extracted earlier
        confidenceMap: confidenceMap, // Store confidence map
        depthWidth: dW,
        depthHeight: dH,
      ),
    );
  }

  // Helper to unpack 16-bit depth from Red/Green channels
  Uint16List _reconstructDepthMap(img.Image depthFrame) {
    final width = depthFrame.width;
    final height = depthFrame.height;
    final depthMap = Uint16List(width * height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final pixel = depthFrame.getPixel(x, y);
        final r = pixel.r.toInt();
        final g = pixel.g.toInt();
        // Formula: Z_mm = (Red * 256) + Green
        depthMap[y * width + x] = (r << 8) | g;
      }
    }
    return depthMap;
  }

  void _parseIntrinsics(String metadata) {
    debugPrint("Parsing Intrinsics from: $metadata");
    final Map<String, double> values = {};

    // Split by comma
    for (var pair in metadata.split(',')) {
      // Split by colon
      final parts = pair.split(':');
      if (parts.length == 2) {
        // TRIM both parts to remove whitespace like " fx" or "500 "
        final key = parts[0].trim();
        final value = double.tryParse(parts[1].trim()) ?? 0.0;
        values[key] = value;
      }
    }

    // Assign to cubit state variables
    final fx = values['fx'];
    final fy = values['fy'];
    final cx = values['cx'];
    final cy = values['cy'];

    // Emit the new state with parsed values
    emit(state.copyWith(fx: fx, fy: fy, cx: cx, cy: cy));

    print('Parsed Intrinsics -> fx: $fx, fy: $fy, cx: $cx, cy: $cy');
  }

  Future<void> pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);

    if (pickedFile != null) {
      final imageFile = File(pickedFile.path);
      final imageBytes = await imageFile.readAsBytes();
      final originalImage = img.decodeImage(imageBytes);

      emit(
        state.copyWith(
          status: SegmentationStatus.success,
          imageFile: imageFile,
          originalImage: originalImage,
          displayImageData: imageBytes,
          maskImageData: null,
          points: [],
          clearMask: true, // Explicitly clear the mask
        ),
      );
    }
  }

  void addPoint(Offset originalPoint) {
    final newPoint = SegmentationPoint(
      point: originalPoint,
      label: state.currentPointLabel,
    );
    final updatedPoints = List<SegmentationPoint>.from(state.points)
      ..add(newPoint);
    emit(state.copyWith(points: updatedPoints));
    _runSegmentation();
  }

  void clearPoints() {
    emit(
      state.copyWith(
        points: [],
        maskImageData: null,
        clearMask: true,
        status: SegmentationStatus.success,
      ),
    );
  }

  void setPointLabel(int label) {
    emit(state.copyWith(currentPointLabel: label));
  }

  void setClassName(String name) {
    emit(state.copyWith(className: name));
  }

  void toggleFillHoles(bool value) {
    emit(state.copyWith(fillHoles: value));
    _runSegmentation();
  }

  void toggleRemoveIslands(bool value) {
    emit(state.copyWith(removeIslands: value));
    _runSegmentation();
  }

  void toggleSelectLargestArea(bool value) {
    emit(state.copyWith(selectLargestArea: value));
    _runSegmentation();
  }

  Future<void> _runSegmentation() async {
    if (_encoderSession == null ||
        _decoderSession == null ||
        state.imageFile == null) {
      return; // Or emit failure state
    }
    if (state.points.isEmpty) {
      emit(state.copyWith(clearMask: true, status: SegmentationStatus.success));
      return;
    }

    emit(state.copyWith(status: SegmentationStatus.processing));

    try {
      final imageForPreprocess = img.decodeImage(
        await state.imageFile!.readAsBytes(),
      )!;

      // Encoder run
      final imageTensor = await _preprocessImage(imageForPreprocess);
      final encoderInputs = {'image': imageTensor};
      final encoderOutputs = await _encoderSession!.run(encoderInputs);
      final imageEmbed = encoderOutputs['image_embed']!;
      final highResFeats0 = encoderOutputs['high_res_feats_0']!;
      final highResFeats1 = encoderOutputs['high_res_feats_1']!;

      // Decoder run
      final pointData = await _preprocessPoints();
      final maskInput = await OrtValue.fromList(
        Float32List(1 * 1 * 256 * 256),
        [1, 1, 256, 256],
      );
      final hasMaskInput = await OrtValue.fromList(
        Float32List.fromList([0.0]),
        [1],
      );

      final Map<String, OrtValue> decoderInputs = {
        'image_embed': imageEmbed,
        'high_res_feats_0': highResFeats0,
        'high_res_feats_1': highResFeats1,
        'point_coords': pointData['onnx_coord']!,
        'point_labels': pointData['onnx_label']!,
        'mask_input': maskInput,
        'has_mask_input': hasMaskInput,
      };

      final decoderOutputs = await _decoderSession!.run(decoderInputs);
      final lowResMasks = decoderOutputs['low_res_masks']!;
      final iouPredictions = decoderOutputs['iou_predictions']!;

      final params = IsolateParams(
        lowResMasksList: (await lowResMasks.asFlattenedList()).cast<double>(),
        iouPredictionsList: (await iouPredictions.asFlattenedList())
            .cast<double>(),
        originalWidth: imageForPreprocess.width,
        originalHeight: imageForPreprocess.height,
        originalImageBytes: await state.imageFile!.readAsBytes(),
        fillHoles: state.fillHoles,
        removeIslands: state.removeIslands,
        selectLargestArea: state.selectLargestArea,
      );

      final IsolateResult result = await compute(
        processAndCompositeInIsolate,
        params,
      );

      emit(
        state.copyWith(
          status: SegmentationStatus.success,
          maskImageData: result.maskImageBytes,
        ),
      );
    } catch (e) {
      debugPrint('Segmentation Error: $e');
      emit(
        state.copyWith(
          status: SegmentationStatus.failure,
          errorMessage: 'Error during segmentation: $e',
        ),
      );
    }
  }

  Future<void> saveImage() async {
    if (state.originalImage == null || state.maskImageData == null) {
      return;
    }
    final maskImage = img.decodePng(state.maskImageData!);
    if (maskImage == null) return;

    emit(state.copyWith(status: SegmentationStatus.saving));

    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final status = await Gal.requestAccess();
        if (!status) {
          emit(
            state.copyWith(
              status: SegmentationStatus.failure,
              errorMessage: 'Storage permission is required to save images.',
            ),
          );
          return;
        }
      }

      final finalImage = img.Image(
        width: state.originalImage!.width,
        height: state.originalImage!.height,
        numChannels: 4,
      );

      for (int y = 0; y < finalImage.height; y++) {
        for (int x = 0; x < finalImage.width; x++) {
          final originalPixel = state.originalImage!.getPixel(x, y);
          final maskPixel = maskImage.getPixel(x, y);
          finalImage.setPixelRgba(
            x,
            y,
            originalPixel.r.toInt(),
            originalPixel.g.toInt(),
            originalPixel.b.toInt(),
            maskPixel.a.toInt(),
          );
        }
      }

      if (state.className.isNotEmpty) {
        finalImage.addTextData({'className': state.className});
      }

      final pngBytes = img.encodePng(finalImage);
      final tempDir = await getTemporaryDirectory();
      final tempPath =
          '${tempDir.path}/segmented_${DateTime.now().millisecondsSinceEpoch}.png';
      final tempFile = await File(tempPath).writeAsBytes(pngBytes);
      await Gal.putImage(tempFile.path);

      // Use a success message in the state if you want to show a snackbar
      emit(state.copyWith(status: SegmentationStatus.success));
    } catch (e) {
      emit(
        state.copyWith(
          status: SegmentationStatus.failure,
          errorMessage: 'Failed to save image: $e',
        ),
      );
    }
  }

  // Preprocessing functions (can be kept private within the cubit)
  Future<OrtValue> _preprocessImage(img.Image image) async {
    final resizedImage = img.copyResize(
      image,
      width: _modelInputSize,
      height: _modelInputSize,
      interpolation: img.Interpolation.linear,
    );
    final inputData = Float32List(1 * 3 * _modelInputSize * _modelInputSize);
    final mean = [123.675, 116.28, 103.53];
    final std = [58.395, 57.12, 57.375];
    int pixelIndex = 0;
    for (int c = 0; c < 3; c++) {
      for (int y = 0; y < _modelInputSize; y++) {
        for (int x = 0; x < _modelInputSize; x++) {
          final pixel = resizedImage.getPixel(x, y);
          double value = (c == 0)
              ? pixel.r.toDouble()
              : (c == 1)
              ? pixel.g.toDouble()
              : pixel.b.toDouble();
          inputData[pixelIndex++] = (value - mean[c]) / std[c];
        }
      }
    }
    return OrtValue.fromList(inputData, [
      1,
      3,
      _modelInputSize,
      _modelInputSize,
    ]);
  }

  Future<Map<String, OrtValue>> _preprocessPoints() async {
    final List<double> pointCoordsList = [];
    final List<double> pointLabelsList = [];
    final int originalWidth = state.originalImage!.width;
    final int originalHeight = state.originalImage!.height;
    for (final p in state.points) {
      final double modelTapX = p.point.dx * (_modelInputSize / originalWidth);
      final double modelTapY = p.point.dy * (_modelInputSize / originalHeight);
      pointCoordsList.addAll([modelTapX, modelTapY]);
      pointLabelsList.add(p.label.toDouble());
    }

    pointCoordsList.addAll([0.0, 0.0]);
    pointLabelsList.add(0.0);
    final int numPoints = state.points.length + 1;
    final coordValue = await OrtValue.fromList(
      Float32List.fromList(pointCoordsList),
      [1, numPoints, 2],
    );
    final labelValue = await OrtValue.fromList(
      Float32List.fromList(pointLabelsList),
      [1, numPoints],
    );
    return {'onnx_coord': coordValue, 'onnx_label': labelValue};
  }

  @override
  Future<void> close() {
    _encoderSession?.close();
    _decoderSession?.close();
    return super.close();
  }

  Future<void> calculateRealWorldDimensions() async {
    if (state.maskImageData == null ||
        state.depthMap == null ||
        state.fx == null ||
        state.depthWidth == null) {
      // print("Missing data for measurement calculation.");
      // print("Mask Data: ${state.maskImageData != null}");
      // print("Depth Map: ${state.depthMap != null}");
      // print("fx: ${state.fx}");
      // print("Depth Width: ${state.depthWidth}");
      emit(
        state.copyWith(
          errorMessage: "Missing depth data or mask. Please load a valid TIFF.",
        ),
      );
      return;
    }

    emit(state.copyWith(status: SegmentationStatus.processing));

    try {
      final maskImage = img.decodePng(state.maskImageData!);
      if (maskImage == null) throw Exception("Could not decode mask.");

      final result = await compute(
        _computeDimensionsInIsolate,
        _MeasurementIsolateParams(
          maskImage: maskImage,
          depthMap: state.depthMap!,
          confidenceMap: state.confidenceMap,
          depthWidth: state.depthWidth!,
          depthHeight: state.depthHeight!,
          fx: state.fx!,
          fy: state.fy!,
          cx: state.cx!,
          cy: state.cy!,
        ),
      );

      emit(
        state.copyWith(
          status: SegmentationStatus.success,
          errorMessage: "Measurement Results:\n$result",
        ),
      );
    } catch (e) {
      emit(
        state.copyWith(
          status: SegmentationStatus.failure,
          errorMessage: "Measurement Failed: $e",
        ),
      );
    }
  }

  // Helper for Isolate
  // Define this struct outside the class or static inside
  static Future<MeasurementResult> _computeDimensionsInIsolate(
    _MeasurementIsolateParams params,
  ) async {
    return MeasurementService.calculateDimensions(
      maskImage: params.maskImage,
      depthMap: params.depthMap,
      depthWidth: params.depthWidth,
      depthHeight: params.depthHeight,
      fx: params.fx,
      fy: params.fy,
      cx: params.cx,
      cy: params.cy,
    );
  }
}

class _MeasurementIsolateParams {
  final img.Image maskImage;
  final Uint16List depthMap;
  final Uint8List? confidenceMap;
  final int depthWidth; // Add this
  final int depthHeight; // Add this
  final double fx, fy, cx, cy;

  _MeasurementIsolateParams({
    required this.maskImage,
    required this.depthMap,
    this.confidenceMap,
    required this.depthWidth,
    required this.depthHeight,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
  });
}
