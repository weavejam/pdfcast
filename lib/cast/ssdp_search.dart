import 'dart:async';
import 'dart:io';

import 'package:dlna_dart/dlna.dart';

/// 补充版 SSDP 搜索：对每块非回环 IPv4 网卡各建一个 socket，把 M-SEARCH 从
/// 该网卡发出去，回复喂给 dlna_dart 的 [DeviceManager.onMessage]。
///
/// 为什么需要：dlna_dart 只用一个 socket 按系统默认组播出口发 M-SEARCH，
/// 本机装了 WSL/Hyper-V/Tailscale 时默认出口常常是虚拟网卡（实测本机走
/// 172.25.96.1 的 WSL vEthernet），包根本到不了真实 Wi-Fi，于是一台设备
/// 都搜不到；显式按网卡设 IP_MULTICAST_IF 后同一台电视立刻回复。
class SsdpMultiInterfaceSearch {
  static final InternetAddress _mcast = InternetAddress('239.255.255.250');
  static const int _port = 1900;

  final List<RawDatagramSocket> _sockets = [];
  Timer? _timer;
  int _round = 0;

  Future<void> start(DeviceManager dm) async {
    List<NetworkInterface> ifaces;
    try {
      ifaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
    } catch (_) {
      return;
    }
    for (final iface in ifaces) {
      try {
        final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        // 未连接的网卡（如 ICS 的 192.168.137.1）这里会抛 10049，跳过即可
        socket.setRawOption(RawSocketOption(
          RawSocketOption.levelIPv4,
          RawSocketOption.IPv4MulticastInterface,
          iface.addresses.first.rawAddress,
        ));
        socket.listen((event) {
          if (event != RawSocketEvent.read) return;
          while (true) {
            final d = socket.receive();
            if (d == null) break;
            try {
              dm.onMessage(String.fromCharCodes(d.data).trim());
            } catch (_) {}
          }
        });
        _sockets.add(socket);
      } catch (_) {}
    }
    if (_sockets.isEmpty) return;
    _send();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _send());
  }

  void _send() {
    // 与 dlna_dart 一致地轮换 ST，兼容只回特定 ST 的设备
    final st = switch (_round++ % 3) {
      0 => 'ssdp:all',
      1 => 'urn:schemas-upnp-org:device:MediaRenderer:1',
      _ => 'urn:schemas-upnp-org:service:AVTransport:1',
    };
    final msg = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'ST: $st\r\n'
        'MX: 3\r\n'
        'MAN: "ssdp:discover"\r\n\r\n';
    for (final s in _sockets) {
      try {
        s.send(msg.codeUnits, _mcast, _port);
      } catch (_) {}
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    for (final s in _sockets) {
      s.close();
    }
    _sockets.clear();
  }
}
