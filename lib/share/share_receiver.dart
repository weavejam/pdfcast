import 'package:flutter/services.dart';

/// 接收系统分享/「打开方式」传进来的 PDF 路径。
/// iOS: AppDelegate openURL；Android: MainActivity intent。
/// Windows 桌面没有对应平台实现，静默忽略。
class ShareReceiver {
  static const _ch = MethodChannel('pdfcast/share');

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
  }
}
