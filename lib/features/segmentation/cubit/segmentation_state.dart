part of 'segmentation_cubit.dart';

enum SegmentationStatus {
  initial,
  loadingModels,
  modelsReady,
  processing,
  saving,
  success,
  failure,
}

class SegmentationState extends Equatable {
  const SegmentationState({
    this.status = SegmentationStatus.initial,
    this.imageFile,
    this.originalImage,
    this.displayImageData,
    this.maskImageData,
    this.points = const [],
    this.currentPointLabel = 1,
    this.fillHoles = false,
    this.removeIslands = false,
    this.selectLargestArea = false,
    this.className = '',
    this.depthMap,
    this.confidenceMap,
    this.depthWidth,
    this.depthHeight,
    this.fx,
    this.fy,
    this.cx,
    this.cy,
    this.measurement,
    this.errorMessage,
  });

  final SegmentationStatus status;
  final File? imageFile;
  final img.Image? originalImage;
  final Uint8List? displayImageData;
  final Uint8List? maskImageData;
  final List<SegmentationPoint> points;
  final int currentPointLabel;
  final bool fillHoles;
  final bool removeIslands;
  final bool selectLargestArea;
  final String className;
  final Uint16List? depthMap; // The 16-bit depth in millimeters
  final Uint8List? confidenceMap; // The 8-bit confidence map
  final int? depthWidth; // Store width of the raw depth map
  final int? depthHeight; // Store height of the raw depth map
  final double? fx; // Focal Length X
  final double? fy; // Focal Length Y
  final double? cx; // Principal Point X
  final double? cy; // Principal Point Y
  final MeasurementResult? measurement;
  final String? errorMessage;

  SegmentationState copyWith({
    SegmentationStatus? status,
    File? imageFile,
    img.Image? originalImage,
    Uint8List? displayImageData,
    Uint8List? maskImageData,
    List<SegmentationPoint>? points,
    int? currentPointLabel,
    bool? fillHoles,
    bool? removeIslands,
    bool? selectLargestArea,
    String? className,
    Uint16List? depthMap,
    Uint8List? confidenceMap,
    int? depthWidth,
    int? depthHeight,
    double? fx,
    double? fy,
    double? cx,
    double? cy,
    MeasurementResult? measurement,
    String? errorMessage,
    bool clearMask = false,
  }) {
    return SegmentationState(
      status: status ?? this.status,
      imageFile: imageFile ?? this.imageFile,
      originalImage: originalImage ?? this.originalImage,
      displayImageData: displayImageData ?? this.displayImageData,
      maskImageData: clearMask ? null : maskImageData ?? this.maskImageData,
      points: points ?? this.points,
      currentPointLabel: currentPointLabel ?? this.currentPointLabel,
      fillHoles: fillHoles ?? this.fillHoles,
      removeIslands: removeIslands ?? this.removeIslands,
      selectLargestArea: selectLargestArea ?? this.selectLargestArea,
      className: className ?? this.className,
      depthMap: depthMap ?? this.depthMap,
      confidenceMap: confidenceMap ?? this.confidenceMap,
      depthWidth: depthWidth ?? this.depthWidth,
      depthHeight: depthHeight ?? this.depthHeight,
      fx: fx ?? this.fx,
      fy: fy ?? this.fy,
      cx: cx ?? this.cx,
      cy: cy ?? this.cy,
      measurement: measurement ?? this.measurement,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }

  @override
  List<Object?> get props => [
    status,
    imageFile,
    originalImage,
    displayImageData,
    maskImageData,
    points,
    currentPointLabel,
    fillHoles,
    removeIslands,
    selectLargestArea,
    className,
    depthMap,
    confidenceMap,
    depthWidth,
    depthHeight,
    fx,
    fy,
    cx,
    cy,
    measurement,
    errorMessage,
  ];
}
