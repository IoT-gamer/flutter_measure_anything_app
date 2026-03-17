import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../capture/view/ar_screen.dart';
import '../cubit/segmentation_cubit.dart';
import 'widgets/point_painter.dart';

class SegmentationPage extends StatefulWidget {
  const SegmentationPage({super.key});

  @override
  State<SegmentationPage> createState() => _SegmentationPageState();
}

class _SegmentationPageState extends State<SegmentationPage> {
  final GlobalKey _imageKey = GlobalKey();
  final TransformationController _transformationController =
      TransformationController();

  void _handleTapUp(TapUpDetails details, SegmentationState state) {
    final cubit = context.read<SegmentationCubit>();
    if (state.imageFile == null ||
        state.status == SegmentationStatus.processing ||
        state.originalImage == null) {
      return;
    }

    final keyContext = _imageKey.currentContext;
    if (keyContext == null) return;

    final RenderBox renderBox = keyContext.findRenderObject() as RenderBox;
    final Size widgetSize = renderBox.size;
    final Offset localPosition = renderBox.globalToLocal(
      details.globalPosition,
    );
    final fittedSizes = applyBoxFit(
      BoxFit.contain,
      Size(
        state.originalImage!.width.toDouble(),
        state.originalImage!.height.toDouble(),
      ),
      widgetSize,
    );
    final Size destSize = fittedSizes.destination;
    final double dx = (widgetSize.width - destSize.width) / 2;
    final double dy = (widgetSize.height - destSize.height) / 2;
    final Rect destRect = Rect.fromLTWH(
      dx,
      dy,
      destSize.width,
      destSize.height,
    );

    if (!destRect.contains(localPosition)) return;

    final double originalX =
        (localPosition.dx - destRect.left) *
        (state.originalImage!.width / destRect.width);
    final double originalY =
        (localPosition.dy - destRect.top) *
        (state.originalImage!.height / destRect.height);

    cubit.addPoint(Offset(originalX, originalY));
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<SegmentationCubit>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Measure Anything'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      floatingActionButton: BlocBuilder<SegmentationCubit, SegmentationState>(
        builder: (context, state) {
          // Hide floating actions if no image is loaded
          if (state.imageFile == null ||
              state.status == SegmentationStatus.processing) {
            return const SizedBox.shrink();
          }
          return Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FloatingActionButton.small(
                onPressed: () => cubit.setPointLabel(1),
                backgroundColor: state.currentPointLabel == 1
                    ? Colors.green
                    : Colors.grey[300],
                tooltip: 'Add Positive Point',
                child: const Icon(Icons.add, color: Colors.white),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.small(
                onPressed: () => cubit.setPointLabel(0),
                backgroundColor: state.currentPointLabel == 0
                    ? Colors.red
                    : Colors.grey[300],
                tooltip: 'Add Negative Point',
                child: const Icon(Icons.remove, color: Colors.white),
              ),
              const SizedBox(height: 8),
              FloatingActionButton.small(
                onPressed: cubit.clearPoints,
                backgroundColor: Colors.blueGrey,
                tooltip: 'Clear All Points',
                child: const Icon(Icons.delete_sweep, color: Colors.white),
              ),
            ],
          );
        },
      ),
      // Listen for Errors or Measurement Results
      body: BlocListener<SegmentationCubit, SegmentationState>(
        listener: (context, state) {
          if (state.errorMessage != null && state.errorMessage!.isNotEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(state.errorMessage!),
                duration: const Duration(seconds: 4),
              ),
            );
          }
        },
        child: Column(
          children: <Widget>[
            // Toggle Controls directly under the AppBar
            BlocBuilder<SegmentationCubit, SegmentationState>(
              buildWhen: (p, c) =>
                  p.imageFile != c.imageFile ||
                  p.points.length != c.points.length ||
                  p.status != c.status,
              builder: (context, state) {
                if (state.imageFile == null ||
                    state.status == SegmentationStatus.processing) {
                  return const SizedBox.shrink();
                }
                if (state.points.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Tap on an object to segment it!'),
                  );
                }
                return Column(
                  children: [
                    SwitchListTile(
                      title: const Text('Fill Holes'),
                      value: state.fillHoles,
                      onChanged: (v) => cubit.toggleFillHoles(v),
                      dense: true,
                      visualDensity: VisualDensity.compact,
                    ),
                    SwitchListTile(
                      title: const Text('Remove Islands'),
                      value: state.removeIslands,
                      onChanged: (v) => cubit.toggleRemoveIslands(v),
                      dense: true,
                      visualDensity: VisualDensity.compact,
                    ),
                    SwitchListTile(
                      title: const Text('Select Largest Area'),
                      value: state.selectLargestArea,
                      onChanged: (value) =>
                          cubit.toggleSelectLargestArea(value),
                      dense: true,
                    ),
                  ],
                );
              },
            ),

            // The Image Viewer (Expanded takes up the remaining middle space)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: BlocBuilder<SegmentationCubit, SegmentationState>(
                  builder: (context, state) {
                    if (state.status == SegmentationStatus.processing) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (state.displayImageData == null) {
                      return const Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.view_in_ar,
                              size: 48,
                              color: Colors.grey,
                            ),
                            SizedBox(height: 16),
                            Text(
                              'Capture an AR scene to start',
                              style: TextStyle(
                                fontSize: 16,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    return GestureDetector(
                      onTapUp: (details) => _handleTapUp(details, state),
                      child: InteractiveViewer(
                        transformationController: _transformationController,
                        minScale: 0.5,
                        maxScale: 4.0,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.memory(
                              state.displayImageData!,
                              key: _imageKey,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            ),
                            if (state.maskImageData != null)
                              Image.memory(
                                state.maskImageData!,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                              ),
                            if (state.originalImage != null)
                              CustomPaint(
                                painter: PointPainter(
                                  state.points,
                                  Size(
                                    state.originalImage!.width.toDouble(),
                                    state.originalImage!.height.toDouble(),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

            // Bottom Buttons (AR Capture, Measure, Save)
            Container(
              padding: const EdgeInsets.all(16.0),
              width: double.infinity,
              color: Colors.grey.shade50,
              child: BlocBuilder<SegmentationCubit, SegmentationState>(
                builder: (context, state) {
                  final modelsLoaded =
                      state.status != SegmentationStatus.initial &&
                      state.status != SegmentationStatus.loadingModels;

                  final isSaving = state.status == SegmentationStatus.saving;

                  final canMeasure =
                      state.maskImageData != null &&
                      state.depthMap != null &&
                      !isSaving;

                  return Wrap(
                    alignment: WrapAlignment.spaceEvenly,
                    spacing: 12.0,
                    runSpacing: 12.0,
                    children: [
                      ElevatedButton.icon(
                        onPressed: modelsLoaded
                            ? () async {
                                final File? capturedFile =
                                    await Navigator.push<File>(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => const ARScreen(),
                                      ),
                                    );

                                if (capturedFile != null) {
                                  cubit.loadCapturedTiff(capturedFile);
                                }
                              }
                            : null,
                        icon: const Icon(Icons.camera),
                        label: const Text('Capture AR Depth'),
                      ),
                      ElevatedButton.icon(
                        onPressed: canMeasure
                            ? cubit.calculateRealWorldDimensions
                            : null,
                        icon: const Icon(Icons.straighten),
                        label: const Text('Measure'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange.shade700,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: (state.maskImageData != null && !isSaving)
                            ? cubit.saveImage
                            : null,
                        icon: isSaving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.save_alt),
                        label: Text(isSaving ? 'Saving' : 'Save PNG'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
