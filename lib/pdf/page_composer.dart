import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'pdf_doc.dart';

/// 电视版式：单页 / 双页并排（像摊开的书）。旋转角度独立于版式。
enum TvLayout {
  single('单页'),
  spread('双页');

  final String label;
  const TvLayout(this.label);
}

/// 合成结果的原始 RGBA 像素（供纯 Dart H.264 编码器使用）
class ComposedRgba {
  final Uint8List rgba;
  final int width;
  final int height;
  ComposedRgba(this.rgba, this.width, this.height);
}

/// 按电视版式合成页面、按 [quarterTurns]×90° 顺时针旋转，输出 RGBA 像素
Future<ComposedRgba> composePageRgba(
  PdfDoc doc,
  int page,
  TvLayout layout,
  int quarterTurns, {
  double longEdge = 1920,
}) async {
  var image = await _composeImage(doc, page, layout, longEdge: longEdge);
  final q = quarterTurns & 3;
  if (q != 0) {
    final rotated = await _rotateQuarters(image, q);
    image.dispose();
    image = rotated;
  }
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return ComposedRgba(
        data!.buffer.asUint8List(), image.width, image.height);
  } finally {
    image.dispose();
  }
}

Future<ui.Image> _composeImage(
  PdfDoc doc,
  int page,
  TvLayout layout, {
  double longEdge = 1920,
}) async {
  switch (layout) {
    case TvLayout.single:
      return doc.renderImage(page, longEdge: longEdge);
    case TvLayout.spread:
      final left = await doc.renderImage(page, longEdge: longEdge);
      ui.Image? right;
      if (page + 1 < doc.pageCount) {
        right = await doc.renderImage(page + 1, longEdge: longEdge);
      }
      try {
        return await _sideBySide(left, right);
      } finally {
        left.dispose();
        right?.dispose();
      }
  }
}

Future<ui.Image> _rotateQuarters(ui.Image src, int q) {
  final w = q.isOdd ? src.height : src.width;
  final h = q.isOdd ? src.width : src.height;
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.translate(w / 2, h / 2);
  canvas.rotate(q * math.pi / 2);
  canvas.translate(-src.width / 2, -src.height / 2);
  canvas.drawImage(src, ui.Offset.zero, ui.Paint());
  return rec.endRecording().toImage(w, h);
}

/// 两页等高并排（末页落单时右侧留白），白底
Future<ui.Image> _sideBySide(ui.Image left, ui.Image? right) {
  final h = left.height;
  double rw = 0;
  double rScale = 1;
  if (right != null) {
    rScale = h / right.height;
    rw = right.width * rScale;
  } else {
    rw = left.width.toDouble(); // 留一页宽的白，保持双页版式不跳动
  }
  final w = (left.width + rw).round();
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  canvas.drawImage(left, ui.Offset.zero, ui.Paint());
  if (right != null) {
    canvas.save();
    canvas.translate(left.width.toDouble(), 0);
    canvas.scale(rScale);
    canvas.drawImage(right, ui.Offset.zero, ui.Paint());
    canvas.restore();
  }
  return rec.endRecording().toImage(w, h);
}
