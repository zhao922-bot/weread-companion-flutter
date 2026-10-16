import 'dart:ui' as ui;
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

/// Engine boundary for bounded card captures. The caller owns each returned
/// image and must dispose it, including when encoding fails or is cancelled.
class CardImageRenderer {
  const CardImageRenderer();

  CardRenderBoundary? findBoundary(GlobalKey key) =>
      key.currentContext?.findRenderObject() as CardRenderBoundary?;

  Future<ui.Image> capture(
          CardRenderBoundary boundary, Rect region, double ratio) =>
      boundary.captureRegion(region, ratio);
}

class CardRepaintBoundary extends SingleChildRenderObjectWidget {
  const CardRepaintBoundary({super.key, required super.child});
  @override
  CardRenderBoundary createRenderObject(BuildContext context) =>
      CardRenderBoundary();
}

class CardRenderBoundary extends RenderRepaintBoundary {
  Future<ui.Image> captureRegion(Rect region, double ratio) =>
      (layer! as OffsetLayer).toImage(region, pixelRatio: ratio);
}
