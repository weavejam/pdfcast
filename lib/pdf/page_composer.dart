import 'dart:typed_data';
import 'dart:ui' as ui;

import 'pdf_doc.dart';

/// 电视横竖屏适配模式
enum TvMode {
  /// 原比例单页，电视自己居中留边
  fit('单页'),

  /// 旋转 90°：竖版 PDF 铺满横屏电视（或反之）
  rotate90('旋转90°'),

  /// 双页并排合成一张横图：横屏电视看竖版 PDF，像摊开的书
  spread('双页');

  final String label;
  const TvMode(this.label);
}

/// 合成结果的原始 RGBA 像素（供纯 Dart H.264 编码器使用）
class ComposedRgba {
  final Uint8List rgba;
  final int width;
  final int height;
  ComposedRgba(this.rgba, this.width, this.height);
}

/// 按电视模式合成页面并输出 RGBA 像素（投屏走 MP4 编码，不经 PNG）
Future<ComposedRgba> composePageRgba(
  PdfDoc doc,
  int page,
  TvMode mode, {
  double longEdge = 1920,
}) async {
  final image = await _composeImage(doc, page, mode, longEdge: longEdge);
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
  TvMode mode, {
  double longEdge = 1920,
}) async {
  switch (mode) {
    case TvMode.fit:
      return doc.renderImage(page, longEdge: longEdge);
    case TvMode.rotate90:
      final img = await doc.renderImage(page, longEdge: longEdge);
      try {
        return await _rotate90(img);
      } finally {
        img.dispose();
      }
    case TvMode.spread:
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

Future<ui.Image> _rotate90(ui.Image src) {
  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.translate(src.height.toDouble(), 0);
  canvas.rotate(1.5707963267948966);
  canvas.drawImage(src, ui.Offset.zero, ui.Paint());
  return rec.endRecording().toImage(src.height, src.width);
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
