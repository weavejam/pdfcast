// 矩阵测试：不同 DIDL 形态 × 图片投屏，全部用全新连接，看哪种能让电视真正来拉图
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const tvBase = 'http://192.168.0.173:62008';

Future<String> soapFresh(String action, String body) async {
  final http = HttpClient();
  try {
    final req = await http.postUrl(Uri.parse('$tvBase/AVTransport/control'));
    req.headers.set(
        'SOAPAction', '"urn:schemas-upnp-org:service:AVTransport:1#$action"');
    req.headers.set('Connection', 'close');
    req.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    req.add(utf8.encode(body));
    final resp = await req.close();
    final text = await resp.transform(utf8.decoder).join();
    final m = RegExp(r'<CurrentTransportState>([^<]+)').firstMatch(text);
    final track = RegExp(r'<TrackURI>([^<]*)').firstMatch(text);
    var extra = '';
    if (m != null) extra = ' state=${m.group(1)}';
    if (track != null) extra += ' track=${track.group(1)}';
    return 'HTTP ${resp.statusCode}$extra${text.contains('Fault') ? ' FAULT: ${text.replaceAll(RegExp(r'\s+'), ' ')}' : ''}';
  } finally {
    http.close(force: true);
  }
}

String setXml(String url, String meta) => '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
<InstanceID>0</InstanceID><CurrentURI>$url</CurrentURI><CurrentURIMetaData>$meta</CurrentURIMetaData>
</u:SetAVTransportURI></s:Body></s:Envelope>''';

const playXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>''';

const infoXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetTransportInfo></s:Body></s:Envelope>''';

const posXml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body><u:GetPositionInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetPositionInfo></s:Body></s:Envelope>''';

String didlRaw(String url, String oclass, String proto) =>
    '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
    '<item id="1" parentID="0" restricted="0"><dc:title>probe</dc:title><upnp:class>$oclass</upnp:class>'
    '<res protocolInfo="$proto">$url</res></item></DIDL-Lite>';

late int fetched;
late List<String> fetchLog;

Future<void> variant(String name, String url, String meta) async {
  final before = fetched;
  print('--- $name');
  try {
    print('  set: ${await soapFresh('SetAVTransportURI', setXml(url, meta))}');
    await Future.delayed(const Duration(milliseconds: 500));
    print('  play: ${await soapFresh('Play', playXml)}');
    await Future.delayed(const Duration(seconds: 6));
    print('  info: ${await soapFresh('GetTransportInfo', infoXml)}');
    print('  pos: ${await soapFresh('GetPositionInfo', posXml)}');
  } catch (e) {
    print('  ERROR: $e');
  }
  print('  fetched during variant: ${fetched - before}');
}

Future<void> main() async {
  fetched = 0;
  fetchLog = [];
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
  server.listen((req) async {
    fetched++;
    print('  >>> TV fetch ${req.method} ${req.uri} UA=${req.headers.value('user-agent')}');
    final bytes = await File('build/probe/test.jpg').readAsBytes();
    req.response.headers.contentType = ContentType('image', 'jpeg');
    req.response.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
  });
  final ip = await _lanIp();

  String freshUrl() =>
      'http://$ip:${server.port}/m/${DateTime.now().microsecondsSinceEpoch}.jpg';

  const esc = HtmlEscape(HtmlEscapeMode.element);

  // A: dlna_dart 原样（未转义 DIDL, imageItem, image/jpeg）
  var u = freshUrl();
  await variant('A unescaped imageItem', u,
      didlRaw(u, 'object.item.imageItem', 'http-get:*:image/jpeg:*'));

  // B: 转义 DIDL, imageItem.photo, JPEG_LRG
  u = freshUrl();
  await variant('B escaped imageItem.photo', u,
      esc.convert(didlRaw(u, 'object.item.imageItem.photo', 'http-get:*:image/jpeg:DLNA.ORG_PN=JPEG_LRG')));

  // C: 空 metadata
  u = freshUrl();
  await variant('C empty metadata', u, '');

  // D: videoItem class + image url（有些电视只走视频管线）
  u = freshUrl();
  await variant('D unescaped videoItem', u,
      didlRaw(u, 'object.item.videoItem', 'http-get:*:image/jpeg:*'));

  print('=== total fetches: $fetched');
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
