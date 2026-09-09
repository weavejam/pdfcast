import 'dart:io';

/// 取局域网 IPv4：电视要通过它来拉手机上的页面图片。
/// 排除虚拟网卡（VMware/Hyper-V/WSL/Docker/Tailscale 等在 Windows 上很常见），
/// 优先无线网卡，其次 192.168.x 网段。
Future<String?> lanIPv4() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
  );
  const virtualHints = [
    'vmware', 'virtual', 'vethernet', 'docker', 'wsl',
    'tailscale', 'zerotier', 'loopback', 'bluetooth', 'vpn',
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
  for (final (_, ip) in candidates) {
    if (ip.startsWith('192.168.')) return ip;
  }
  return candidates.first.$2;
}
