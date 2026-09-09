// 验证 Play 失败是否是 keep-alive 连接复用竞态：每个 SOAP 请求用全新连接 + Connection: close
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const tvBase = 'http://192.168.0.173:62008';

Future<String> soapFresh(String action, String body) async {
  final http = HttpClient();
  try {
    final req = await http.postUrl(Uri.parse('$tvBase/AVTransport/control'));
    req.headers.set('SOAPAction',
        '"urn:schemas-upnp-org:service:AVTransport:1#$action"');
    req.headers.set('Connection', 'close');
    req.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    req.add(utf8.encode(body));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    return 'HTTP ${resp.statusCode} ${text.replaceAll(RegExp(r'\s+'), ' ').trim()}';
  } finally {
    http.close(force: true);
  }
}

String setXml(String url, String didlEscaped) => '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID><CurrentURI>$url</CurrentURI><CurrentURIMetaData>$didlEscaped</CurrentURIMetaData>
</u:SetAVTransportURI></s:Body></s:Envelope>''';

const playXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>''';

const stopXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Stop></s:Body></s:Envelope>''';

const infoXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetTransportInfo></s:Body></s:Envelope>''';

Future<void> step(String name, Future<String> Function() f) async {
  try {
    final r = await f();
    print('$name: ${r.length > 320 ? r.substring(0, 320) : r}');
  } catch (e) {
    print('$name FAILED: $e');
  }
}

Future<void> main() async {
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
      'http://$ip:${server.port}/fresh/${DateTime.now().millisecondsSinceEpoch}.jpg';
  print('url: $url');

  final didl =
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="1" parentID="0" restricted="1">'
      '<dc:title>fresh probe</dc:title>'
      '<upnp:class>object.item.imageItem.photo</upnp:class>'
      '<res protocolInfo="http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG">$url</res>'
      '</item></DIDL-Lite>';
  final escaped = const HtmlEscape(HtmlEscapeMode.attribute).convert(didl);

  await step('Stop', () => soapFresh('Stop', stopXml));
  await step('TransportInfo(before)', () => soapFresh('GetTransportInfo', infoXml));
  await step('SetAVTransportURI', () => soapFresh('SetAVTransportURI', setXml(url, escaped)));
  await Future.delayed(const Duration(seconds: 1));
  await step('Play', () => soapFresh('Play', playXml));
  await Future.delayed(const Duration(seconds: 3));
  await step('TransportInfo(after)', () => soapFresh('GetTransportInfo', infoXml));
  await Future.delayed(const Duration(seconds: 7));
  print('=== fetched: $fetched');
  await server.close(force: true);
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
