import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// A small Android GPU surface draws only the moving layer. No Dart frame timer
/// or Flutter texture copy; Flutter keeps static rings, labels and semantics.
class NativeRadarMotion extends StatefulWidget {
  const NativeRadarMotion({
    super.key,
    required this.active,
    required this.searching,
    required this.animate,
    required this.backgroundColor,
    this.onUnavailable,
  });

  final bool active, searching, animate;
  final Color backgroundColor;
  final VoidCallback? onUnavailable;

  @override
  State<NativeRadarMotion> createState() => _NativeRadarMotionState();
}

class _NativeRadarMotionState extends State<NativeRadarMotion> {
  MethodChannel? _channel;
  Map<String, Object> get _state => {
    'active': widget.active,
    'searching': widget.searching,
    'animate': widget.animate,
    'backgroundColor': widget.backgroundColor.toARGB32(),
  };

  @override
  void didUpdateWidget(covariant NativeRadarMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        oldWidget.searching != widget.searching ||
        oldWidget.animate != widget.animate ||
        oldWidget.backgroundColor != widget.backgroundColor) {
      _sync();
    }
  }

  Future<void> _sync() async {
    try {
      await _channel?.invokeMethod<void>('update', _state);
    } on PlatformException {
      if (mounted) widget.onUnavailable?.call();
    } on MissingPluginException {
      if (mounted) widget.onUnavailable?.call();
    }
  }

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: PlatformViewLink(
      viewType: 'farvahartrends/radar',
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      ),
      onCreatePlatformView: (params) {
        // Explicit hybrid composition keeps the GPU surface in the native
        // view hierarchy instead of feeding a new Flutter texture every frame.
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: 'farvahartrends/radar',
          layoutDirection: TextDirection.ltr,
          creationParams: _state,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        controller.addOnPlatformViewCreatedListener((id) {
          params.onPlatformViewCreated(id);
          if (!mounted) return;
          _channel = MethodChannel('farvahartrends/radar/$id');
          _channel!.setMethodCallHandler((call) async {
            if (call.method == 'unavailable' && mounted) {
              widget.onUnavailable?.call();
            }
          });
          _sync();
        });
        controller.create();
        return controller;
      },
    ),
  );
}
