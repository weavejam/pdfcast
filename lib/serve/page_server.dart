import 'dart:io';
import 'dart:typed_data';

import '../pdf/page_composer.dart';
import '../pdf/pdf_doc.dart';
import 'lan_ip.dart';
import 'still_mp4.dart';

/// 本地 HTTP server：把 PDF 页面按需编成静态画面 H.264 MP4 给电视拉取。
/// 走视频而非图片：实测有电视（YUPP 等 stagefright renderer）对 DLNA
/// 图片投屏静默丢弃，但 H.264/MP4 稳定播放。
/// URL 规则：`/d/<docId>/p/<page>-<mode>-<edge>.mp4`
/// 参数全部编进路径（不用 query string，避免 & 在 DIDL/CurrentURI 里的
/// 转义歧义）；任何参数变化 URL 必变——电视缓存激进，URL 唯一性是
/// 换页正确显示的前提。
class PageServer {
  PageServer._();
  static final PageServer i = PageServer._();

  HttpServer? _server;
  String? _ip;
  PdfDoc? _doc;

  final _cache = <String, Uint8List>{};
  static const _cacheMax = 6; // 每个 1080p MP4 约 3MB

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

  /// 电视要拉的页面视频 URL。必须先 ensureStarted + serveDoc。
  String pageUrl(int page, TvMode mode, {int longEdge = 1920}) {
    final doc = _doc!;
    return 'http://$_ip:${_server!.port}'
        '/d/${doc.id}/p/$page-${mode.name}-$longEdge.mp4';
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final doc = _doc;
      // 路径: /d/<docId>/p/<page>-<mode>-<edge>.mp4
      final seg = req.uri.pathSegments;
      if (doc == null ||
          seg.length != 4 ||
          seg[0] != 'd' ||
          seg[1] != doc.id ||
          seg[2] != 'p' ||
          !seg[3].endsWith('.mp4')) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final parts = seg[3].substring(0, seg[3].length - 4).split('-');
      if (parts.length != 3) {
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final page = int.parse(parts[0]);
      final mode = TvMode.values.asNameMap()[parts[1]] ?? TvMode.fit;
      final longEdge = double.tryParse(parts[2]) ?? 1920;

      final key = '${doc.id}/$page/${mode.name}/$longEdge';
      var bytes = _cache.remove(key);
      if (bytes == null) {
        final c = await composePageRgba(doc, page, mode, longEdge: longEdge);
        bytes = encodeStillMp4(
            rgba: c.rgba, width: c.width, height: c.height);
      }
      _cache[key] = bytes;
      while (_cache.length > _cacheMax) {
        _cache.remove(_cache.keys.first);
      }

      // stagefright 用 Range 探测/拉流，必须支持 206
      var start = 0;
      var end = bytes.length - 1;
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        if (m != null) {
          start = int.parse(m.group(1)!);
          if (m.group(2)!.isNotEmpty) end = int.parse(m.group(2)!);
          if (start > end || end >= bytes.length) {
            req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
            await req.response.close();
            return;
          }
          req.response.statusCode = HttpStatus.partialContent;
          req.response.headers
              .set('Content-Range', 'bytes $start-$end/${bytes.length}');
        }
      }
      req.response.headers.contentType = ContentType('video', 'mp4');
      req.response.headers.set('Accept-Ranges', 'bytes');
      req.response.headers.set('Cache-Control', 'no-store');
      req.response.contentLength = end - start + 1;
      req.response.add(bytes.sublist(start, end + 1));
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
