import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

/// Only gestures starting at a screen edge enter the horizontal gesture arena.
class SpaceSwipe extends StatelessWidget {
  const SpaceSwipe({
    super.key,
    required this.child,
    required this.onSwitch,
    this.enabled = true,
  });
  final Widget child;
  final ValueChanged<int> onSwitch;
  final bool enabled;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      return RawGestureDetector(
        gestures: {
          _EdgeDrag: GestureRecognizerFactoryWithHandlers<_EdgeDrag>(
            () => _EdgeDrag(),
            (recognizer) {
              recognizer.width = constraints.maxWidth;
              recognizer.enabled = enabled;
              recognizer.onStart = (_) => recognizer.distance = 0;
              recognizer.onUpdate = (details) =>
                  recognizer.distance += details.primaryDelta ?? 0;
              recognizer.onEnd = (details) {
                final direction = recognizer.direction;
                final inward = recognizer.distance * direction;
                final velocity = (details.primaryVelocity ?? 0) * direction;
                if (recognizer.enabled &&
                    (inward >= 64 || (inward >= 24 && velocity >= 600))) {
                  onSwitch(direction);
                }
              };
            },
          ),
        },
        child: child,
      );
    },
  );
}

class _EdgeDrag extends HorizontalDragGestureRecognizer {
  double width = 0;
  double distance = 0;
  bool enabled = true;
  int direction = 1;

  @override
  bool isPointerAllowed(PointerEvent event) {
    if (event is! PointerDownEvent) return false;
    final x = event.localPosition.dx;
    if (!enabled || (x > 24 && x < width - 24)) return false;
    direction = x <= 24 ? 1 : -1;
    return super.isPointerAllowed(event);
  }
}
