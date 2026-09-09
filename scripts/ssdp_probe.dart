// 最小 SSDP 探测：复刻 dlna_dart 的发现路径，验证当前 Dart SDK 下 M-SEARCH 是否能收到回复
import 'dart:io';

Future<void> main() async {
  final mcast = InternetAddress('239.255.255.250');
  final client = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  print('client bound: ${client.address.address}:${client.port}');
  var got = 0;
  client.listen((e) {
    if (e == RawSocketEvent.read) {
      while (true) {
        final d = client.receive();
        if (d == null) break;
        got++;
        final msg = String.fromCharCodes(d.data);
        final firstLine = msg.split('\r\n').first;
        final loc = RegExp(r'location:\s*(\S+)', caseSensitive: false)
            .firstMatch(msg)
            ?.group(1);
        print('reply #$got from ${d.address.address}:${d.port} [$firstLine] $loc');
      }
    }
  });
  const msg = 'M-SEARCH * HTTP/1.1\r\n'
      'HOST: 239.255.255.250:1900\r\n'
      'ST: ssdp:all\r\n'
      'MX: 1\r\n'
      'MAN: "ssdp:discover"\r\n\r\n';
  for (var i = 0; i < 3; i++) {
    final sent = client.send(msg.codeUnits, mcast, 1900);
    print('M-SEARCH sent ($sent bytes)');
    await Future.delayed(const Duration(seconds: 2));
  }
  print('total replies: $got');
  client.close();
}
