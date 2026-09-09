import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'pdf_doc.dart';

/// 首页缩略图的磁盘缓存：文档打开时生成一次，文件库网格直接读文件，
/// 避免为了封面把每个 PDF 都打开一遍。
class ThumbCache {
  static Directory? _dir;

  static Future<Directory> _ensureDir() async {
    if (_dir != null) return _dir!;
    final cache = await getApplicationCacheDirectory();
    final d = Directory('${cache.path}${Platform.pathSeparator}thumbs');
    if (!d.existsSync()) d.createSync(recursive: true);
    _dir = d;
    return d;
  }

  static String _keyOf(String path) =>
      md5.convert(path.codeUnits).toString().substring(0, 16);

  /// 已有缩略图则返回文件，否则 null
  static Future<File?> fileFor(String path) async {
    final dir = await _ensureDir();
    final f = File('${dir.path}${Platform.pathSeparator}${_keyOf(path)}.png');
    return f.existsSync() ? f : null;
  }

  /// 为已打开的文档生成缩略图（幂等）
  static Future<void> generate(PdfDoc doc) async {
    final dir = await _ensureDir();
    final f =
        File('${dir.path}${Platform.pathSeparator}${_keyOf(doc.path)}.png');
    if (f.existsSync()) return;
    try {
      final bytes = await doc.renderPng(0, longEdge: 480);
      await f.writeAsBytes(bytes);
    } catch (_) {}
  }
}
