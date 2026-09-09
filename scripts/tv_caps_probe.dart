// 查电视 DLNA 能力：设备描述 + ConnectionManager GetProtocolInfo（Sink 支持哪些格式）
// 再用「规范转义的 DIDL」重试投图，观察电视是否来拉图。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const tvBase = 'http://192.168.0.173:62008';

Future<void> main() async {
  final http = HttpClient();

  // 1. 设备描述
  String? desc;
  for (final path in ['/', '/description.xml', '/dmr.xml', '/rootDesc.xml']) {
    try {
      final req = await http.getUrl(Uri.parse('$tvBase$path'));
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == 200 && body.contains('<device')) {
        print('description at $path (${body.length} bytes)');
        desc = body;
        break;
      }
    } catch (e) {
      print('GET $path -> $e');
    }
  }
  if (desc == null) {
    print('no device description found');
    return;
  }
  final cmCtl = RegExp(
          r'ConnectionManager[\s\S]{0,400}?<controlURL>([^<]+)</controlURL>')
      .firstMatch(desc)
      ?.group(1);
  print('ConnectionManager controlURL: $cmCtl');

  // 2. GetProtocolInfo
  if (cmCtl != null) {
    const body = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:GetProtocolInfo xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1"></u:GetProtocolInfo></s:Body>
</s:Envelope>''';
    try {
      final r = await _soap(
          http,
          '$tvBase${cmCtl.startsWith('/') ? '' : '/'}$cmCtl',
          'urn:schemas-upnp-org:service:ConnectionManager:1#GetProtocolInfo',
          body);
      final sink =
          RegExp(r'<Sink>([\s\S]*?)</Sink>').firstMatch(r)?.group(1) ?? '';
      print('--- Sink protocols ---');
      for (final p in sink.split(',')) {
        if (p.contains('image') || p.trim().isEmpty) print('  $p');
      }
      print('image formats: ${sink.contains('image') ? 'FOUND' : 'NONE'}');
      print('total sink entries: ${sink.split(',').length}');
      final preview = sink.length > 600 ? sink.substring(0, 600) : sink;
      print('sink head: $preview');
    } catch (e) {
      print('GetProtocolInfo FAILED: $e');
    }
  }

  // 3. 规范转义 DIDL 的 SetAVTransportURI + Play，本地起 server 看电视拉不拉图
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
  var fetched = 0;
  server.listen((req) async {
    fetched++;
    print('>>> TV fetched ${req.uri} UA=${req.headers.value('user-agent')}');
    final bytes = await File('build/probe/test.jpg').readAsBytes();
    req.response.headers.contentType = ContentType('image', 'jpeg');
    req.response.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  });
  final ip = await _lanIp();
  final url =
      'http://$ip:${server.port}/escaped/${DateTime.now().millisecondsSinceEpoch}.jpg';
  print('--- escaped-DIDL cast: $url');

  final didl =
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
      'xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
      '<item id="1" parentID="0" restricted="1">'
      '<dc:title>probe escaped</dc:title>'
      '<upnp:class>object.item.imageItem.photo</upnp:class>'
      '<res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG;DLNA.ORG_FLAGS=00d00000000000000000000000000000">$url</res>'
      '</item></DIDL-Lite>';
  final escaped = const HtmlEscape(HtmlEscapeMode.attribute).convert(didl);
  final setBody = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID>
<CurrentURI>$url</CurrentURI>
<CurrentURIMetaData>$escaped</CurrentURIMetaData>
</u:SetAVTransportURI></s:Body></s:Envelope>''';
  try {
    final r = await _soap(http, '$tvBase/AVTransport/control',
        'urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI', setBody);
    print('setUrl resp: ${_head(r)}');
  } catch (e) {
    print('setUrl FAILED: $e');
  }
  const playBody = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>''';
  try {
    final r = await _soap(http, '$tvBase/AVTransport/control',
        'urn:schemas-upnp-org:service:AVTransport:1#Play', playBody);
    print('play resp: ${_head(r)}');
  } catch (e) {
    print('play FAILED: $e');
  }
  await Future.delayed(const Duration(seconds: 10));
  print('=== fetched: $fetched');
  await server.close(force: true);
  http.close(force: true);
}

Future<String> _soap(
    HttpClient http, String url, String action, String body) async {
  final req = await http.postUrl(Uri.parse(url));
  req.headers.set('SOAPAction', '"$action"');
  req.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
  req.add(utf8.encode(body));
  final resp = await req.close();
  final text = await resp.transform(utf8.decoder).join();
  return 'HTTP ${resp.statusCode} $text';
}

String _head(String s, [int n = 300]) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length <= n ? t : '${t.substring(0, n)}…';
}

Future<String> _lanIp() async {
  final ifaces = await NetworkInterface.list(
      includeLoopback: false, type: InternetAddressType.IPv4);
  for (final i in ifaces) {
    for (final a in i.addresses) {
      if (a.address.startsWith('192.168.0.')) return a.address;
    }
  }
  return ifaces.first.addresses.first.address;
}
