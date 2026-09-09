import 'package:wakelock_plus/wakelock_plus.dart';

/// 引用计数的屏幕常亮：投屏会话期间保持手机不锁屏，
/// 否则 iOS 挂起 app 后本地 HTTP server 停摆，电视拉不到图。
class ScreenAwake {
  static int _n = 0;

  static void acquire() {
    if (_n++ == 0) WakelockPlus.enable();
  }

  static void release() {
    if (_n > 0 && --_n == 0) WakelockPlus.disable();
  }

  /// iOS 的 idleTimerDisabled 是全局开关，可能被其他组件关掉，周期性重新断言
  static void refresh() {
    if (_n > 0) WakelockPlus.enable();
  }
}
