// 端到端验证 SsdpMultiInterfaceSearch：应在几秒内发现局域网电视
import 'package:dlna_dart/dlna.dart';
import 'package:pdfcast/cast/ssdp_search.dart';

Future<void> main() async {
  final dm = DeviceManager();
  final search = SsdpMultiInterfaceSearch();
  dm.devices.stream.listen((map) {
    for (final e in map.entries) {
      print('device: ${e.value.info.friendlyName} @ ${e.key}');
    }
  });
  await search.start(dm);
  await Future.delayed(const Duration(seconds: 8));
  print('total devices: ${dm.deviceList.length}');
  search.stop();
  dm.dispose();
}
