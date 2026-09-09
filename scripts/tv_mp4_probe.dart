// 决定性验证：H.264 baseline MP4 投 videoItem，电视 stagefright 应能播
import 'dart:async';
import 'dart:convert';
import 'dart:io';

const tvBase = 'http://192.168.0.173:62008';

Future<String> soapFresh(String action, String body, {int retries = 3}) async {
  for (var i = 0;; i++) {
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
      final state =
          RegExp(r'<CurrentTransportState>([^<]+)').firstMatch(text)?.group(1);
      final fault = text.contains('Fault');
      return 'HTTP ${resp.statusCode}${state != null ? ' state=$state' : ''}${fault ? ' FAULT' : ''}';
    } catch (e) {
      if (i >= retries) rethrow;
      await Future.delayed(const Duration(seconds: 2));
    } finally {
      http.close(force: true);
    }
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

String didl(String url) =>
    '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
    '<item id="1" parentID="0" restricted="0"><dc:title>pdfcast mp4 probe</dc:title><upnp:class>object.item.videoItem</upnp:class>'
    '<res protocolInfo="http-get:*:video/mp4:*">$url</res></item></DIDL-Lite>';

Future<void> main(List<String> args) async {
  final mp4 = await File(args.isNotEmpty ? args[0] : 'build/probe/test.mp4')
      .readAsBytes();
  var fetched = 0;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
  server.listen((req) async {
    fetched++;
    print(
        '  >>> TV ${req.method} ${req.uri} range=${req.headers.value('range')} UA=${req.headers.value('user-agent')}');
    final range = req.headers.value('range');
    var start = 0;
    var end = mp4.length - 1;
    if (range != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (m != null) {
        start = int.parse(m.group(1)!);
        if (m.group(2)!.isNotEmpty) end = int.parse(m.group(2)!);
        req.response.statusCode = 206;
        req.response.headers
            .set('Content-Range', 'bytes $start-$end/${mp4.length}');
      }
    }
    req.response.headers.contentType = ContentType('video', 'mp4');
    req.response.headers.set('Accept-Ranges', 'bytes');
    req.response.contentLength = end - start + 1;
    req.response.add(mp4.sublist(start, end + 1));
    await req.response.close();
  });
  final ip = await _lanIp();
  final url =
      'http://$ip:${server.port}/page${DateTime.now().millisecondsSinceEpoch}.mp4';
  print('casting $url');
  print('  set: ${await soapFresh('SetAVTransportURI', setXml(url, didl(url)))}');
  await Future.delayed(const Duration(milliseconds: 500));
  print('  play: ${await soapFresh('Play', playXml)}');
  for (var i = 0; i < 10; i++) {
    await Future.delayed(const Duration(seconds: 3));
    try {
      print('  info: ${await soapFresh('GetTransportInfo', infoXml, retries: 0)}');
    } catch (e) {
      print('  info FAILED: $e');
    }
  }
  print('=== total fetches: $fetched');
  await server.close(force: true);
  exit(0);
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
