// 决定性实验：图片路径被电视无视，改走视频管线——
// E) 纯 Dart 合成 MJPEG-AVI（每帧就是一张 JPEG）投 videoItem
// F) 无限 raw MJPEG 流（若能播，翻页可即时换帧，免重新投）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const tvBase = 'http://192.168.0.173:62008';

// ---------- 最小 MJPEG-AVI 合成 ----------
Uint8List buildMjpegAvi(Uint8List jpeg, int frames, int fps, int w, int h) {
  Uint8List u32(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
  Uint8List u16(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
  Uint8List fourcc(String s) => Uint8List.fromList(ascii.encode(s));

  Uint8List chunk(String cc, List<int> data) {
    final b = BytesBuilder();
    b.add(fourcc(cc));
    b.add(u32(data.length));
    b.add(data);
    if (data.length.isOdd) b.addByte(0);
    return b.toBytes();
  }

  Uint8List list(String cc, List<int> data) {
    final b = BytesBuilder();
    b.add(fourcc('LIST'));
    b.add(u32(4 + data.length));
    b.add(fourcc(cc));
    b.add(data);
    return b.toBytes();
  }

  final jLen = jpeg.length;
  final jPad = jLen.isOdd ? jLen + 1 : jLen;

  final avih = BytesBuilder()
    ..add(u32(1000000 ~/ fps)) // dwMicroSecPerFrame
    ..add(u32(jLen * fps)) // dwMaxBytesPerSec
    ..add(u32(0)) // padding
    ..add(u32(0x10)) // AVIF_HASINDEX
    ..add(u32(frames))
    ..add(u32(0)) // initial frames
    ..add(u32(1)) // streams
    ..add(u32(jPad + 8)) // suggested buffer
    ..add(u32(w))
    ..add(u32(h))
    ..add(Uint8List(16)); // reserved

  final strh = BytesBuilder()
    ..add(fourcc('vids'))
    ..add(fourcc('MJPG'))
    ..add(u32(0)) // flags
    ..add(u16(0)) // priority
    ..add(u16(0)) // language
    ..add(u32(0)) // initial frames
    ..add(u32(1)) // scale
    ..add(u32(fps)) // rate
    ..add(u32(0)) // start
    ..add(u32(frames)) // length
    ..add(u32(jPad + 8))
    ..add(u32(0xFFFFFFFF)) // quality -1
    ..add(u32(0)) // sample size
    ..add(u16(0))
    ..add(u16(0))
    ..add(u16(w))
    ..add(u16(h));

  final strf = BytesBuilder()
    ..add(u32(40)) // biSize
    ..add(u32(w))
    ..add(u32(h))
    ..add(u16(1)) // planes
    ..add(u16(24)) // bitcount
    ..add(fourcc('MJPG'))
    ..add(u32(jLen))
    ..add(Uint8List(16));

  final strl = list(
      'strl',
      (BytesBuilder()
            ..add(chunk('strh', strh.toBytes()))
            ..add(chunk('strf', strf.toBytes())))
          .toBytes());
  final hdrl = list(
      'hdrl',
      (BytesBuilder()
            ..add(chunk('avih', avih.toBytes()))
            ..add(strl))
          .toBytes());

  final moviBody = BytesBuilder();
  final offsets = <int>[];
  for (var i = 0; i < frames; i++) {
    offsets.add(4 + moviBody.length); // 相对 'movi' fourcc 起点
    moviBody.add(chunk('00dc', jpeg));
  }
  final movi = list('movi', moviBody.toBytes());

  final idxBody = BytesBuilder();
  for (final off in offsets) {
    idxBody
      ..add(fourcc('00dc'))
      ..add(u32(0x10)) // AVIIF_KEYFRAME
      ..add(u32(off))
      ..add(u32(jLen));
  }
  final idx1 = chunk('idx1', idxBody.toBytes());

  final body = BytesBuilder()
    ..add(fourcc('AVI '))
    ..add(hdrl)
    ..add(movi)
    ..add(idx1);
  final riff = BytesBuilder()
    ..add(fourcc('RIFF'))
    ..add(u32(body.length))
    ..add(body.toBytes());
  return riff.toBytes();
}

// ---------- SOAP ----------
Future<String> soapFresh(String action, String body, {int retries = 3}) async {
  for (var i = 0;; i++) {
    final http = HttpClient();
    try {
      final req =
          await http.postUrl(Uri.parse('$tvBase/AVTransport/control'));
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

String didl(String url, String proto) =>
    '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">'
    '<item id="1" parentID="0" restricted="0"><dc:title>pdfcast page</dc:title><upnp:class>object.item.videoItem</upnp:class>'
    '<res protocolInfo="$proto">$url</res></item></DIDL-Lite>';

Future<void> main() async {
  final jpeg = await File('build/probe/test.jpg').readAsBytes();
  final avi = buildMjpegAvi(jpeg, 30, 1, 1920, 1080); // 30 帧 1fps = 30 秒
  print('AVI size: ${avi.length} bytes');
  await File('build/probe/test.avi').writeAsBytes(avi);

  var fetched = 0;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
  server.listen((req) async {
    fetched++;
    print(
        '  >>> TV ${req.method} ${req.uri} range=${req.headers.value('range')} UA=${req.headers.value('user-agent')}');
    if (req.uri.path.contains('stream')) {
      // 无限 raw MJPEG：持续重发同一帧
      req.response.headers.contentType = ContentType('video', 'avi');
      try {
        while (true) {
          req.response.add(jpeg);
          await req.response.flush();
          await Future.delayed(const Duration(milliseconds: 500));
        }
      } catch (_) {
        print('  >>> stream closed by TV');
      }
      return;
    }
    // AVI 文件（支持 Range）
    final range = req.headers.value('range');
    var start = 0;
    var end = avi.length - 1;
    if (range != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (m != null) {
        start = int.parse(m.group(1)!);
        if (m.group(2)!.isNotEmpty) end = int.parse(m.group(2)!);
        req.response.statusCode = 206;
        req.response.headers
            .set('Content-Range', 'bytes $start-$end/${avi.length}');
      }
    }
    req.response.headers.contentType = ContentType('video', 'avi');
    req.response.headers.set('Accept-Ranges', 'bytes');
    req.response.contentLength = end - start + 1;
    req.response.add(avi.sublist(start, end + 1));
    await req.response.close();
  });
  final ip = await _lanIp();
  print('server at http://$ip:${server.port}');

  Future<void> variant(String name, String url, String proto) async {
    final before = fetched;
    print('--- $name: $url');
    try {
      print('  set: ${await soapFresh('SetAVTransportURI', setXml(url, didl(url, proto)))}');
      await Future.delayed(const Duration(milliseconds: 500));
      print('  play: ${await soapFresh('Play', playXml)}');
      for (var i = 0; i < 5; i++) {
        await Future.delayed(const Duration(seconds: 3));
        try {
          print('  info: ${await soapFresh('GetTransportInfo', infoXml, retries: 0)}');
        } catch (e) {
          print('  info FAILED: $e');
        }
      }
    } catch (e) {
      print('  ERROR: $e');
    }
    print('  fetches in variant: ${fetched - before}');
  }

  final ts = DateTime.now().millisecondsSinceEpoch;
  await variant('E MJPEG-AVI videoItem',
      'http://$ip:${server.port}/clip$ts.avi', 'http-get:*:video/avi:*');
  await Future.delayed(const Duration(seconds: 3));
  await variant('F endless MJPEG stream',
      'http://$ip:${server.port}/stream$ts.avi', 'http-get:*:video/avi:*');

  print('=== total fetches: $fetched');
  await Future.delayed(const Duration(seconds: 2));
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
