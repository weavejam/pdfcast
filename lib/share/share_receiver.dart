import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 接收系统分享/「打开方式」传进来的 PDF 路径。
/// iOS: AppDelegate openURL + Share Extension（App Group 共享容器）；
/// Android: MainActivity intent。Windows 桌面没有对应平台实现，静默忽略。
class ShareReceiver {
  static const _ch = MethodChannel('pdfcast/share');
  static _ResumePuller? _puller;

  /// [onPdf] 收到一个可读的本地 PDF 路径（平台侧已拷到 app 可读位置）
  static void listen(void Function(String path) onPdf) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onPdf' && call.arguments is String) {
        onPdf(call.arguments as String);
      }
    });
    // 冷启动：app 是被分享唤起的，启动完成后取平台缓存的首个路径
    _ch.invokeMethod<String>('getInitialPdf').then((path) {
      if (path != null && path.isNotEmpty) onPdf(path);
    }).catchError((_) {
      // Windows / 未实现平台：忽略
    });
    // Share Extension 把文件放进 App Group 共享容器，主 App 拉不到推送
    // （extension 与 app 是两个进程），启动和每次回前台时主动取一遍
    _pullImports(onPdf);
    if (_puller == null) {
      _puller = _ResumePuller(() => _pullImports(onPdf));
      WidgetsBinding.instance.addObserver(_puller!);
    }
  }

  static Future<void> _pullImports(void Function(String) onPdf) async {
    try {
      final paths = await _ch.invokeMethod<List<Object?>>('takePendingImports');
      for (final p in paths ?? const <Object?>[]) {
        if (p is String && p.isNotEmpty) onPdf(p);
      }
    } catch (_) {
      // Android/Windows 未实现该方法：忽略
    }
  }
}

class _ResumePuller with WidgetsBindingObserver {
  final VoidCallback onResume;
  _ResumePuller(this.onResume);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}
