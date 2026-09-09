// 端到端投图诊断：发现电视 → 起 HTTP server 供图 → setUrl(PNG/JPEG)+play，
// 记录电视是否真的来拉图、SOAP 返回什么、TransportInfo 状态如何。
import 'dart:async';
import 'dart:io';

import 'package:dlna_dart/dlna.dart';
import 'package:dlna_dart/xmlParser.dart' show ImageMime, PlayType;
import 'package:pdfcast/cast/ssdp_search.dart';

Future<void> main() async {
  // 1. 发现电视
  final dm = DeviceManager();
  final search = SsdpMultiInterfaceSearch();
  await search.start(dm);
  DLNADevice? tv;
  for (var i = 0; i < 16 && tv == null; i++) {
    await Future.delayed(const Duration(milliseconds: 500));
    for (final e in dm.deviceList.entries) {
      tv = e.value;
      print('found: ${e.value.info.friendlyName} @ ${e.key}');
    }
  }
  search.stop();
  final dev = tv;
  if (dev == null) {
    print('no device found');
    dm.dispose();
    return;
  }

  // 2. 本地 server 供两张测试图
  final ip = await _lanIp();
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
  final hits = <String>[];
  server.listen((req) async {
    final ua = req.headers.value('user-agent') ?? '-';
    hits.add(req.uri.path);
    print('>>> TV fetched ${req.uri} from ${req.connectionInfo?.remoteAddress.address} UA=$ua');
    final f = req.uri.path.endsWith('.jpg')
        ? File('build/probe/test.jpg')
        : File('build/probe/test.png');
    final bytes = await f.readAsBytes();
    req.response.headers.contentType =
        ContentType('image', req.uri.path.endsWith('.jpg') ? 'jpeg' : 'png');
    req.response.contentLength = bytes.length;
    req.response.add(bytes);
    await req.response.close();
    print('>>> served ${bytes.length} bytes for ${req.uri.path}');
  });
  final base = 'http://$ip:${server.port}';
  print('server at $base');

  Future<void> tryCast(String label, String url, PlayType type) async {
    print('--- $label: setUrl $url');
    try {
      final r = await dev.setUrl(url, title: 'probe $label', type: type);
      print('setUrl resp: ${_head(r)}');
    } catch (e) {
      print('setUrl FAILED: $e');
      return;
    }
    try {
      final r = await dev.play();
      print('play resp: ${_head(r)}');
    } catch (e) {
      print('play FAILED: $e');
    }
    await Future.delayed(const Duration(seconds: 8));
    try {
      final r = await dev.position();
      print('position resp: ${_head(r, 400)}');
    } catch (e) {
      print('position FAILED: $e');
    }
  }

  await tryCast('PNG imageItem', '$base/probe/${DateTime.now().millisecondsSinceEpoch}.png', ImageMime.png);
  await tryCast('JPEG imageItem', '$base/probe/${DateTime.now().millisecondsSinceEpoch}.jpg', ImageMime.jpeg);

  print('=== total fetches: ${hits.length} -> $hits');
  await server.close(force: true);
  dm.dispose();
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
