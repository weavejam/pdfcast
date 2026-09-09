import 'dart:io';
import 'dart:typed_data';

import '../pdf/page_composer.dart';
import '../pdf/pdf_doc.dart';
import 'lan_ip.dart';

/// 本地 HTTP server：把 PDF 页面按需渲染成 PNG 给电视拉取。
/// URL 含 docId+页码+模式+分辨率，任何参数变化 URL 必变——
/// 电视端图片缓存激进，URL 唯一性是换页正确显示的前提。
class PageServer {
  PageServer._();
  static final PageServer i = PageServer._();

  HttpServer? _server;
  String? _ip;
  PdfDoc? _doc;

  final _cache = <String, Uint8List>{};
  static const _cacheMax = 12;

  bool get running => _server != null;

  /// 启动（幂等）。返回 base url，如 http://192.168.1.5:38080
  Future<String> ensureStarted() async {
    if (_server != null && _ip != null) {
      return 'http://$_ip:${_server!.port}';
    }
    final ip = await lanIPv4();
    if (ip == null) {
      throw Exception('未找到局域网 IP，请确认已连接 Wi-Fi');
    }
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.listen(_handle, onError: (_) {});
    _server = server;
    _ip = ip;
    return 'http://$ip:${server.port}';
  }

  void serveDoc(PdfDoc doc) {
    if (_doc?.id != doc.id) _cache.clear();
    _doc = doc;
  }

  /// 停止投屏后不再对外提供该文档（doc 可能随后被 dispose）
  void clearDoc() {
    _doc = null;
    _cache.clear();
  }

  /// 电视要拉的页面图片 URL。必须先 ensureStarted + serveDoc。
  String pageUrl(int page, TvMode mode, {int longEdge = 1920}) {
    final doc = _doc!;
    return 'http://$_ip:${_server!.port}'
        '/d/${doc.id}/p/$page.png?m=${mode.name}&e=$longEdge';
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final doc = _doc;
      // 路径: /d/<docId>/p/<page>.png
      final seg = req.uri.pathSegments;
      if (doc == null ||
          seg.length != 4 ||
          seg[0] != 'd' ||
          seg[1] != doc.id ||
          seg[2] != 'p' ||
          !seg[3].endsWith('.png')) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final page = int.parse(seg[3].substring(0, seg[3].length - 4));
      final mode = TvMode.values.asNameMap()[req.uri.queryParameters['m']] ??
          TvMode.fit;
      final longEdge =
          double.tryParse(req.uri.queryParameters['e'] ?? '') ?? 1920;

      final key = '${doc.id}/$page/${mode.name}/$longEdge';
      var bytes = _cache.remove(key);
      bytes ??= await composePage(doc, page, mode, longEdge: longEdge);
      _cache[key] = bytes;
      while (_cache.length > _cacheMax) {
        _cache.remove(_cache.keys.first);
      }

      req.response.headers.contentType = ContentType('image', 'png');
      req.response.headers.set('Cache-Control', 'no-store');
      req.response.contentLength = bytes.length;
      req.response.add(bytes);
      await req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _ip = null;
    _cache.clear();
  }
}
