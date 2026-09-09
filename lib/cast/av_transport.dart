// 直连 AVTransport SOAP：每次请求全新连接 + Connection: close。
// 原因：部分电视（如 YUPP）每个 SOAP 响应后立刻关 socket，dlna_dart 的
// 共享 HttpClient 会复用死连接报 "Connection closed before full header"。
// 另外 dlna_dart 只会按 imageItem/videoItem 固定模板投 setUrl，
// 这台电视对 imageItem 静默丢弃，必须自己拼 videoItem DIDL。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dlna_dart/dlna.dart';

class AvTransport {
  final Uri control;

  AvTransport(DLNADevice device)
      : control = Uri.parse(device.controlURL('AVTransport'));

  Future<void> setVideoUri(String url, String title) async {
    final didl = _didlVideo(url, title);
    await _soap('SetAVTransportURI', '''
<u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID><CurrentURI>${_xml(url)}</CurrentURI><CurrentURIMetaData>${_xml(didl)}</CurrentURIMetaData>
</u:SetAVTransportURI>''');
  }

  Future<void> play() => _soap('Play',
      '<u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>');

  Future<void> stop() => _soap('Stop',
      '<u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Stop>');

  Future<void> _soap(String action, String body) async {
    final envelope = '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>$body</s:Body></s:Envelope>';
    final http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await http.postUrl(control);
      req.headers.set('SOAPAction',
          '"urn:schemas-upnp-org:service:AVTransport:1#$action"');
      req.headers.set('Connection', 'close');
      req.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
      req.add(utf8.encode(envelope));
      // 有电视处理 SetAVTransportURI 要十几秒才回响应（命令其实已生效），
      // 超时给足；真正联不通由 5s connectionTimeout 兜底
      final resp = await req.close().timeout(const Duration(seconds: 20));
      final text = await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode >= 400 || text.contains('Fault')) {
        throw Exception('$action 失败：HTTP ${resp.statusCode}');
      }
    } finally {
      http.close(force: true);
    }
  }

  static String _didlVideo(String url, String title) =>
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
      'xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
      '<item id="1" parentID="0" restricted="0">'
      '<dc:title>${_xml(title)}</dc:title>'
      '<upnp:class>object.item.videoItem</upnp:class>'
      '<res protocolInfo="http-get:*:video/mp4:*">${_xml(url)}</res>'
      '</item></DIDL-Lite>';

  static String _xml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
