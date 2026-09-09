import 'dart:async';

import 'package:dlna_dart/dlna.dart';
import 'package:flutter/cupertino.dart';

import '../pdf/page_composer.dart';
import '../pdf/pdf_doc.dart';
import '../screen_awake.dart';
import '../serve/page_server.dart';
import 'av_transport.dart';

/// 全局投屏会话：持有设备与当前页，翻页 = 重新 SetAVTransportURI
/// 推该页的静态画面 MP4 URL（图片投屏部分电视静默丢弃，视频稳）。
class CastSession extends ChangeNotifier {
  CastSession._();
  static final CastSession i = CastSession._();

  DLNADevice? _device;
  AvTransport? _av;
  PdfDoc? doc;

  /// 阅读页退出时若仍在投屏，把 doc 的释放责任移交给会话（stop 时 dispose）
  bool ownsDoc = false;
  String docName = '';
  int page = 0;
  TvLayout layout = TvLayout.single;

  /// 顺时针旋转 90° 的次数（0~3），对应 0/90/180/270°
  int quarterTurns = 0;
  int longEdge = 1920;

  bool pushing = false;
  String? lastError;

  Timer? _autoTimer;
  int autoIntervalSec = 8;
  bool get autoFlipOn => _autoTimer != null;

  Timer? _awakeTimer;

  bool get active => _device != null;
  String get deviceName => _device?.info.friendlyName ?? '';

  /// 双页模式一次跨两页
  int get _step => layout == TvLayout.spread ? 2 : 1;

  void Function(int page)? onPageShown;

  Future<void> start(
    DLNADevice device,
    PdfDoc document,
    String name,
    int startPage,
  ) async {
    final base = await PageServer.i.ensureStarted();
    debugPrint('PageServer at $base');
    PageServer.i.serveDoc(document);
    final old = _device;
    if (old == null) {
      ScreenAwake.acquire();
      _awakeTimer =
          Timer.periodic(const Duration(minutes: 1), (_) => ScreenAwake.refresh());
    }
    if (old != null && old != device) {
      try {
        await _av?.stop();
      } catch (_) {}
    }
    _device = device;
    _av = AvTransport(device);
    if (ownsDoc && doc != null && !identical(doc, document)) {
      doc!.dispose();
    }
    ownsDoc = false;
    doc = document;
    docName = name;
    page = startPage;
    try {
      await _pushCurrent();
    } on TimeoutException {
      // 电视响应慢于超时但命令多半已生效（实测报超时后几秒画面照样出来）：
      // 保留会话进遥控页，只在状态行提示，不当失败拆会话
      lastError = '电视响应慢，画面可能稍后出现；没画面就点重试';
    } catch (e) {
      if (old == null) _teardownAwake();
      _device = null;
      _av = null;
      doc = null;
      notifyListeners();
      rethrow;
    }
    notifyListeners();
  }

  Future<void> switchDevice(DLNADevice device) async {
    final old = _device;
    final oldAv = _av;
    _device = device;
    _av = AvTransport(device);
    try {
      await _pushCurrent();
    } catch (e) {
      _device = old;
      _av = oldAv;
      rethrow;
    } finally {
      notifyListeners();
    }
    if (old != null && old != device) {
      try {
        await oldAv?.stop();
      } catch (_) {}
    }
  }

  // ---- 翻页 ----

  bool get hasNext => doc != null && page + _step < doc!.pageCount;
  bool get hasPrev => page > 0;

  void next() {
    if (hasNext) goTo(page + _step);
  }

  void prev() {
    if (hasPrev) goTo((page - _step).clamp(0, doc!.pageCount - 1));
  }

  /// UI 先行显示目标页，推送节流：快速连翻只把最终停留页推给电视
  void goTo(int target) {
    final d = doc;
    if (d == null) return;
    page = target.clamp(0, d.pageCount - 1);
    notifyListeners();
    _schedulePush();
  }

  void setLayout(TvLayout l) {
    if (layout == l) return;
    layout = l;
    if (l == TvLayout.spread) page -= page % 2; // 双页对齐到偶数页起
    notifyListeners();
    _schedulePush();
  }

  void setRotation(int quarters) {
    final q = quarters & 3;
    if (quarterTurns == q) return;
    quarterTurns = q;
    notifyListeners();
    _schedulePush();
  }

  /// 手动重推当前页（推送失败/超时后的重试入口）
  void repush() {
    lastError = null;
    notifyListeners();
    _schedulePush();
  }

  int? _pendingPage;

  void _schedulePush() {
    if (!active) return;
    if (pushing) {
      _pendingPage = page;
      return;
    }
    _pushCurrent().catchError((e) {
      lastError = '推送失败：$e';
      notifyListeners();
    });
  }

  Future<void> _pushCurrent() async {
    final av = _av;
    final d = doc;
    if (av == null || d == null) return;
    pushing = true;
    lastError = null;
    notifyListeners();
    try {
      final url =
          PageServer.i.pageUrl(page, layout, quarterTurns, longEdge: longEdge);
      await av.setVideoUri(url, '$docName 第${page + 1}页');
      // SetAVTransportURI 后紧接 Play 有电视会丢，稍等再发
      await Future.delayed(const Duration(milliseconds: 300));
      await av.play();
      onPageShown?.call(page);
    } finally {
      pushing = false;
      notifyListeners();
      final pending = _pendingPage;
      _pendingPage = null;
      if (pending != null && pending != page) {
        // 状态已过期（用户又翻了），推最新页
        _schedulePush();
      } else if (pending != null) {
        await _pushCurrent();
      }
    }
  }

  // ---- 定时翻页 ----

  void startAutoFlip(int intervalSec) {
    autoIntervalSec = intervalSec;
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(Duration(seconds: intervalSec), (_) {
      if (!hasNext) {
        stopAutoFlip();
        return;
      }
      next();
    });
    notifyListeners();
  }

  void stopAutoFlip() {
    _autoTimer?.cancel();
    _autoTimer = null;
    notifyListeners();
  }

  // ---- 结束 ----

  Future<void> stop() async {
    final av = _av;
    _device = null;
    _av = null;
    stopAutoFlip();
    _teardownAwake();
    _pendingPage = null;
    lastError = null;
    PageServer.i.clearDoc();
    if (ownsDoc) {
      doc?.dispose();
      ownsDoc = false;
    }
    doc = null;
    notifyListeners();
    if (av != null) {
      try {
        await av.stop();
      } catch (_) {}
    }
  }

  void _teardownAwake() {
    _awakeTimer?.cancel();
    _awakeTimer = null;
    ScreenAwake.release();
  }
}
