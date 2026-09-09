import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/cupertino.dart';

import '../pdf/pdf_doc.dart';
import 'cast_session.dart';
import 'ssdp_search.dart';

/// 弹出投屏面板：搜索局域网 DLNA 设备，点选后把 [doc] 从 [startPage] 投出去。
/// 投屏中再次打开可换设备或停止投屏。投屏成功后回调 [onCasting]。
Future<void> showCastSheet(
  BuildContext context, {
  required PdfDoc doc,
  required String docName,
  required int startPage,
  VoidCallback? onCasting,
}) {
  return showCupertinoModalPopup(
    context: context,
    builder: (_) => _CastSheet(
      doc: doc,
      docName: docName,
      startPage: startPage,
      onCasting: onCasting,
    ),
  );
}

class _CastSheet extends StatefulWidget {
  final PdfDoc doc;
  final String docName;
  final int startPage;
  final VoidCallback? onCasting;
  const _CastSheet({
    required this.doc,
    required this.docName,
    required this.startPage,
    this.onCasting,
  });

  @override
  State<_CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<_CastSheet> {
  final DLNAManager _manager = DLNAManager();
  final SsdpMultiInterfaceSearch _extraSearch = SsdpMultiInterfaceSearch();
  DeviceManager? _fallbackDm;
  List<DLNADevice> _devices = const [];
  StreamSubscription? _sub;
  bool _connecting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    CastSession.i.addListener(_onSession);
    _search();
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  Future<void> _search() async {
    DeviceManager dm;
    try {
      // reusePort：B 站等 app 投屏时会占住 SSDP 的 1900 端口，必须共享绑定
      // （Windows 不支持 reusePort，Dart 只打日志不报错，1900 被独占时才抛）
      dm = await _manager.start(reusePort: true);
    } catch (_) {
      // 1900 绑不上（被其他投屏 app 独占）：收不到 NOTIFY 广播，但多网卡
      // M-SEARCH 的回复走临时端口，照样能发现设备
      dm = _fallbackDm = DeviceManager();
    }
    // devices 是单订阅流，每次打开面板都新建 DeviceManager，不能复用
    _sub = dm.devices.stream.listen((map) {
      if (mounted) setState(() => _devices = map.values.toList());
    });
    // dlna_dart 的 M-SEARCH 只从系统默认组播出口发，遇到 WSL/虚拟网卡就发错口，
    // 这里补一份按网卡逐个发的搜索（详见 ssdp_search.dart）
    await _extraSearch.start(dm);
  }

  @override
  void dispose() {
    CastSession.i.removeListener(_onSession);
    _sub?.cancel();
    _extraSearch.stop();
    _manager.stop();
    _fallbackDm?.dispose();
    super.dispose();
  }

  Future<void> _cast(DLNADevice device) async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      if (CastSession.i.active && CastSession.i.doc?.id == widget.doc.id) {
        await CastSession.i.switchDevice(device);
      } else {
        // 未投屏，或投屏中打开了另一个文档：直接投新内容（旧设备会被停掉）
        await CastSession.i.start(
          device,
          widget.doc,
          widget.docName,
          widget.startPage,
        );
      }
      widget.onCasting?.call();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _error = '投屏失败：$e';
    }
    if (mounted) setState(() => _connecting = false);
  }

  @override
  Widget build(BuildContext context) {
    final casting = CastSession.i.active;
    final others = casting
        ? _devices
            .where((d) => d.info.friendlyName != CastSession.i.deviceName)
            .toList()
        : _devices;
    return CupertinoActionSheet(
      title: casting
          ? Text('正在投屏到「${CastSession.i.deviceName}」')
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text('选择投屏设备'),
                SizedBox(width: 8),
                CupertinoActivityIndicator(radius: 8),
              ],
            ),
      message: _error != null
          ? Text(_error!)
          : _connecting
              ? const Text('正在连接…')
              : casting
                  ? (others.isEmpty
                      ? const Text('正在搜索其他可投屏的设备…')
                      : const Text('点其他设备可直接换过去接着看'))
                  : _devices.isEmpty
                      ? const Text('正在搜索局域网里的电视/投屏设备…\n请确认手机和电视连着同一个 Wi-Fi')
                      : null,
      actions: [
        for (final d in others)
          CupertinoActionSheetAction(
            onPressed: _connecting ? () {} : () => _cast(d),
            child: Text(
                casting ? '换到「${d.info.friendlyName}」' : d.info.friendlyName),
          ),
        if (casting)
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              CastSession.i.stop();
              Navigator.pop(context);
            },
            child: const Text('停止投屏'),
          ),
      ],
      cancelButton: CupertinoActionSheetAction(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    );
  }
}
