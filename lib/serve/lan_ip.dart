import 'dart:io';

/// 取局域网 IPv4：电视要通过它来拉手机上的页面视频。
/// 排除虚拟网卡（Windows 上的 VMware/Hyper-V/WSL/Docker/Tailscale，
/// iOS 上的 VPN utun/ipsec、蜂窝 pdp_ip、AirDrop awdl 等）——选错网卡
/// 电视根本连不到手机，表现为投屏后一直转圈。
/// 优先无线网卡，其次私网网段。
Future<String?> lanIPv4() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
  );
  const virtualHints = [
    // Windows / 桌面
    'vmware', 'virtual', 'vethernet', 'docker', 'wsl',
    'tailscale', 'zerotier', 'loopback', 'bluetooth', 'vpn',
    // iOS：utun*=VPN，ipsec*=旧 VPN，pdp_ip*=蜂窝，awdl/llw=AirDrop 类，
    // anpi*=调试口，bridge*=热点桥
    'utun', 'ipsec', 'pdp_ip', 'awdl', 'llw', 'anpi', 'bridge',
  ];
  const wifiHints = ['wlan', 'wi-fi', 'wifi', 'en0', '无线'];

  final candidates = <(String name, String ip)>[];
  for (final itf in interfaces) {
    final name = itf.name.toLowerCase();
    if (virtualHints.any(name.contains)) continue;
    for (final addr in itf.addresses) {
      if (addr.isLoopback) continue;
      candidates.add((name, addr.address));
    }
  }
  if (candidates.isEmpty) return null;
  for (final (name, ip) in candidates) {
    if (wifiHints.any(name.contains)) return ip;
  }
  bool isPrivate(String ip) {
    if (ip.startsWith('192.168.') || ip.startsWith('10.')) return true;
    final m = RegExp(r'^172\.(\d+)\.').firstMatch(ip);
    if (m != null) {
      final b = int.parse(m.group(1)!);
      return b >= 16 && b <= 31;
    }
    return false;
  }

  for (final (_, ip) in candidates) {
    if (isPrivate(ip)) return ip;
  }
  return candidates.first.$2;
}
