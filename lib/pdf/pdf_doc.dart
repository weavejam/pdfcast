import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:pdfrx/pdfrx.dart';

/// pdfrx 文档封装：按页渲染成 ui.Image / PNG，带 LRU 缓存。
/// docId 由文件内容摘要生成，保证投屏 URL 随文档内容唯一（电视缓存激进）。
class PdfDoc {
  final PdfDocument _doc;
  final String path;
  final String id;

  PdfDoc._(this._doc, this.path, this.id);

  static Future<PdfDoc> open(String path) async {
    // pdfrx 2.x：直接用 PdfDocument API（不经 PdfViewer/PdfDocumentRef）必须先初始化
    await pdfrxFlutterInitialize();
    final doc = await PdfDocument.openFile(path);
    final f = File(path);
    final stat = f.statSync();
    final digest =
        md5.convert('$path|${stat.size}|${stat.modified.millisecondsSinceEpoch}'
            .codeUnits);
    return PdfDoc._(doc, path, digest.toString().substring(0, 12));
  }

  int get pageCount => _doc.pages.length;

  /// 页面宽高比（宽/高），用于 UI 布局与判断横竖版
  double aspectOf(int page) {
    final p = _doc.pages[page];
    return p.width / p.height;
  }

  // pdfium 渲染串行化，避免并发渲染崩溃
  Future<void> _lock = Future.value();

  Future<T> _serial<T>(Future<T> Function() job) {
    final done = Completer<void>();
    final prev = _lock;
    _lock = done.future;
    return prev.then((_) => job()).whenComplete(done.complete);
  }

  /// 渲染一页为 ui.Image，长边 [longEdge] 像素。调用方负责 dispose。
  Future<ui.Image> renderImage(int page, {double longEdge = 1920}) {
    return _serial(() async {
      final p = _doc.pages[page];
      final scale = longEdge / (p.width > p.height ? p.width : p.height);
      final w = (p.width * scale).round();
      final h = (p.height * scale).round();
      final img = await p.render(
        fullWidth: w.toDouble(),
        fullHeight: h.toDouble(),
        backgroundColor: 0xFFFFFFFF,
      );
      if (img == null) {
        throw Exception('渲染第 ${page + 1} 页失败');
      }
      try {
        return await img.createImage();
      } finally {
        img.dispose();
      }
    });
  }

  final _pngCache = <String, Uint8List>{};
  static const _cacheMax = 24;

  /// 渲染一页为 PNG bytes（LRU 缓存）
  Future<Uint8List> renderPng(int page, {double longEdge = 1920}) async {
    final key = '$page@$longEdge';
    final hit = _pngCache.remove(key);
    if (hit != null) {
      _pngCache[key] = hit; // 触摸移到队尾
      return hit;
    }
    final image = await renderImage(page, longEdge: longEdge);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = data!.buffer.asUint8List();
      _pngCache[key] = bytes;
      while (_pngCache.length > _cacheMax) {
        _pngCache.remove(_pngCache.keys.first);
      }
      return bytes;
    } finally {
      image.dispose();
    }
  }

  void dispose() {
    _pngCache.clear();
    _doc.dispose();
  }
}
