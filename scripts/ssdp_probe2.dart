// SSDP 深度探测：按网卡设置组播出口逐个发 M-SEARCH + 绑 1900 收 NOTIFY
import 'dart:io';
import 'dart:typed_data';

Future<void> main() async {
  final mcast = InternetAddress('239.255.255.250');
  final ifaces = await NetworkInterface.list(
      includeLoopback: false, type: InternetAddressType.IPv4);
  for (final i in ifaces) {
    print('iface: ${i.name} ${i.addresses.map((a) => a.address).toList()}');
  }

  // server socket: 1900 + join group（收 NOTIFY 广播）
  final server = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 1900,
      reusePort: true);
  try {
    server.joinMulticast(mcast);
    print('joinMulticast(default) ok');
  } catch (e) {
    print('joinMulticast(default) FAILED: $e');
  }
  for (final i in ifaces) {
    try {
      server.joinMulticast(mcast, i);
      print('joinMulticast(${i.name}) ok');
    } catch (e) {
      print('joinMulticast(${i.name}) failed: $e');
    }
  }
  var notify = 0;
  server.listen((e) {
    if (e == RawSocketEvent.read) {
      while (true) {
        final d = server.receive();
        if (d == null) break;
        notify++;
        final first = String.fromCharCodes(d.data).split('\r\n').first;
        if (notify <= 5) print('server got from ${d.address.address} [$first]');
      }
    }
  });

  const msg = 'M-SEARCH * HTTP/1.1\r\n'
      'HOST: 239.255.255.250:1900\r\n'
      'ST: ssdp:all\r\n'
      'MX: 1\r\n'
      'MAN: "ssdp:discover"\r\n\r\n';

  final client = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  var replies = 0;
  client.listen((e) {
    if (e == RawSocketEvent.read) {
      while (true) {
        final d = client.receive();
        if (d == null) break;
        replies++;
        final loc = RegExp(r'location:\s*(\S+)', caseSensitive: false)
            .firstMatch(String.fromCharCodes(d.data))
            ?.group(1);
        print('client reply from ${d.address.address} $loc');
      }
    }
  });

  // 默认出口
  client.send(msg.codeUnits, mcast, 1900);
  print('sent via default egress');
  await Future.delayed(const Duration(seconds: 2));
  print('replies so far: $replies');

  // 逐网卡设置 IP_MULTICAST_IF (level IPPROTO_IP=0, option 9 on Windows)
  for (final i in ifaces) {
    try {
      final addr = i.addresses.first;
      client.setRawOption(RawSocketOption(
          RawSocketOption.levelIPv4, 9, Uint8List.fromList(addr.rawAddress)));
      client.send(msg.codeUnits, mcast, 1900);
      print('sent via ${i.name} (${addr.address})');
    } catch (e) {
      print('set IP_MULTICAST_IF ${i.name} failed: $e');
    }
    await Future.delayed(const Duration(seconds: 2));
    print('replies so far: $replies');
  }

  await Future.delayed(const Duration(seconds: 4));
  print('TOTAL client replies: $replies, server datagrams: $notify');
  client.close();
  server.close();
}
