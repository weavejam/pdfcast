import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../cast/cast_session.dart';
import '../pdf/page_composer.dart';
import '../pdf/pdf_doc.dart';

/// 投屏遥控页：同步大图预览（左右滑=翻页）、上/下页按钮、页码滑杆、
/// 缩略图条、定时翻页、电视横竖屏模式切换。
class RemotePage extends StatefulWidget {
  const RemotePage({super.key});

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  final _session = CastSession.i;
  PageController? _pc;
  final _thumbCtrl = ScrollController();
  bool _syncing = false; // 程序驱动的翻页，不再回推

  static const _thumbW = 56.0;
  static const _thumbGap = 8.0;

  @override
  void initState() {
    super.initState();
    _pc = PageController(initialPage: _session.page);
    _session.addListener(_onSession);
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    _pc?.dispose();
    _thumbCtrl.dispose();
    super.dispose();
  }

  void _onSession() {
    if (!mounted) return;
    if (!_session.active) {
      Navigator.of(context).pop();
      return;
    }
    final pc = _pc;
    if (pc != null && pc.hasClients) {
      final cur = pc.page?.round() ?? _session.page;
      if (cur != _session.page) {
        _syncing = true;
        pc
            .animateToPage(
              _session.page,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
            )
            .whenComplete(() => _syncing = false);
      }
    }
    _scrollThumbTo(_session.page);
    setState(() {});
  }

  void _scrollThumbTo(int page) {
    if (!_thumbCtrl.hasClients) return;
    final target = page * (_thumbW + _thumbGap) -
        (_thumbCtrl.position.viewportDimension - _thumbW) / 2;
    _thumbCtrl.animateTo(
      target.clamp(0.0, _thumbCtrl.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _onSwiped(int p) {
    if (_syncing) return;
    if (p != _session.page) _session.goTo(p);
  }

  void _confirmStop() {
    showCupertinoModalPopup(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(ctx);
              _session.stop(); // 会话结束会触发本页 pop
            },
            child: const Text('停止投屏'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final doc = _session.doc;
    if (doc == null) {
      return const CupertinoPageScaffold(child: SizedBox.shrink());
    }
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGrey6,
      navigationBar: CupertinoNavigationBar(
        middle: Text('投屏到「${_session.deviceName}」',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _confirmStop,
          child: const Text('断开',
              style: TextStyle(color: CupertinoColors.destructiveRed)),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Expanded(child: _preview(doc)),
            _statusLine(doc),
            _slider(doc),
            _thumbStrip(doc),
            _pageButtons(),
            _modeAndTimer(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _preview(PdfDoc doc) {
    return PageView.builder(
      controller: _pc,
      onPageChanged: _onSwiped,
      itemCount: doc.pageCount,
      itemBuilder: (_, i) => _PagePreview(doc: doc, page: i),
    );
  }

  Widget _statusLine(PdfDoc doc) {
    final err = _session.lastError;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_session.pushing) ...[
            const CupertinoActivityIndicator(radius: 7),
            const SizedBox(width: 6),
            const Text('推送中…',
                style: TextStyle(
                    fontSize: 12, color: CupertinoColors.systemGrey)),
          ] else if (err != null) ...[
            Flexible(
              child: Text(err,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, color: CupertinoColors.destructiveRed)),
            ),
            CupertinoButton(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 0),
              onPressed: _session.repush,
              child: const Text('重试', style: TextStyle(fontSize: 12)),
            ),
          ] else
            Text('${_session.page + 1} / ${doc.pageCount}',
                style: const TextStyle(
                    fontSize: 12, color: CupertinoColors.systemGrey)),
        ],
      ),
    );
  }

  Widget _slider(PdfDoc doc) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: CupertinoSlider(
        value: _session.page.toDouble().clamp(0, (doc.pageCount - 1).toDouble()),
        min: 0,
        max: (doc.pageCount - 1).toDouble(),
        onChanged: (v) => _session.goTo(v.round()),
      ),
    );
  }

  Widget _thumbStrip(PdfDoc doc) {
    return SizedBox(
      height: 76,
      child: ListView.separated(
        controller: _thumbCtrl,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: doc.pageCount,
        separatorBuilder: (_, _) => const SizedBox(width: _thumbGap),
        itemBuilder: (_, i) {
          final current = i == _session.page;
          return GestureDetector(
            onTap: () => _session.goTo(i),
            child: Container(
              width: _thumbW,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: CupertinoColors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: current
                      ? CupertinoColors.activeBlue
                      : CupertinoColors.systemGrey4,
                  width: current ? 2 : 1,
                ),
              ),
              child: _Thumb(doc: doc, page: i),
            ),
          );
        },
      ),
    );
  }

  Widget _pageButtons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: CupertinoButton.tinted(
              onPressed: _session.hasPrev ? _session.prev : null,
              child: const Icon(CupertinoIcons.chevron_left, size: 28),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: CupertinoButton.tinted(
              onPressed: _session.hasNext ? _session.next : null,
              child: const Icon(CupertinoIcons.chevron_right, size: 28),
            ),
          ),
        ],
      ),
    );
  }

  void _pickRotation() {
    showCupertinoModalPopup(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: const Text('电视画面旋转'),
        actions: [
          for (var q = 0; q < 4; q++)
            CupertinoActionSheetAction(
              onPressed: () {
                Navigator.pop(ctx);
                _session.setRotation(q);
              },
              child: Text(_session.quarterTurns == q ? '✓ ${q * 90}°' : '${q * 90}°'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
  }

  Widget _modeAndTimer() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Row(
            children: [
              const Text('电视画面', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 12),
              Expanded(
                child: CupertinoSlidingSegmentedControl<TvLayout>(
                  groupValue: _session.layout,
                  children: {
                    for (final l in TvLayout.values)
                      l: Text(l.label, style: const TextStyle(fontSize: 13)),
                  },
                  onValueChanged: (l) {
                    if (l != null) _session.setLayout(l);
                  },
                ),
              ),
              const SizedBox(width: 12),
              CupertinoButton(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                minimumSize: const Size(0, 0),
                color: CupertinoColors.tertiarySystemFill,
                borderRadius: BorderRadius.circular(8),
                onPressed: _pickRotation,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('旋转 ${_session.quarterTurns * 90}°',
                        style: const TextStyle(
                            fontSize: 13, color: CupertinoColors.label)),
                    const Icon(CupertinoIcons.chevron_down,
                        size: 14, color: CupertinoColors.systemGrey),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('定时翻页', style: TextStyle(fontSize: 13)),
              const SizedBox(width: 12),
              CupertinoSwitch(
                value: _session.autoFlipOn,
                onChanged: (on) {
                  if (on) {
                    _session.startAutoFlip(_session.autoIntervalSec);
                  } else {
                    _session.stopAutoFlip();
                  }
                },
              ),
              const SizedBox(width: 12),
              if (_session.autoFlipOn)
                Expanded(
                  child: CupertinoSlidingSegmentedControl<int>(
                    groupValue: _session.autoIntervalSec,
                    children: const {
                      5: Text('5秒', style: TextStyle(fontSize: 12)),
                      10: Text('10秒', style: TextStyle(fontSize: 12)),
                      20: Text('20秒', style: TextStyle(fontSize: 12)),
                      30: Text('30秒', style: TextStyle(fontSize: 12)),
                      60: Text('1分', style: TextStyle(fontSize: 12)),
                    },
                    onValueChanged: (v) {
                      if (v != null) _session.startAutoFlip(v);
                    },
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PagePreview extends StatelessWidget {
  final PdfDoc doc;
  final int page;
  const _PagePreview({required this.doc, required this.page});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: doc.renderPng(page, longEdge: 1200),
      builder: (_, snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('预览失败：${snap.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 12, color: CupertinoColors.destructiveRed)),
            ),
          );
        }
        final bytes = snap.data;
        if (bytes == null) {
          return const Center(child: CupertinoActivityIndicator());
        }
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Image.memory(bytes, gaplessPlayback: true),
          ),
        );
      },
    );
  }
}

/// 缩略图带内存缓存：避免滑动缩略图条时反复渲染
class _Thumb extends StatelessWidget {
  static final _cache = <String, Uint8List>{};
  final PdfDoc doc;
  final int page;
  const _Thumb({required this.doc, required this.page});

  Future<Uint8List> _load() async {
    final key = '${doc.id}/$page';
    final hit = _cache[key];
    if (hit != null) return hit;
    final bytes = await doc.renderPng(page, longEdge: 200);
    if (_cache.length > 200) _cache.clear();
    _cache[key] = bytes;
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _load(),
      builder: (_, snap) {
        final bytes = snap.data;
        if (bytes == null) return const SizedBox.expand();
        return Image.memory(bytes, fit: BoxFit.contain);
      },
    );
  }
}
