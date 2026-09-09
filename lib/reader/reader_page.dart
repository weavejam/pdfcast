import 'dart:typed_data';

import 'package:flutter/cupertino.dart';

import '../cast/cast_panel.dart';
import '../cast/cast_session.dart';
import '../library/recent_store.dart';
import '../pdf/pdf_doc.dart';
import '../pdf/thumb_cache.dart';
import 'remote_page.dart';

/// 本地阅读页：PageView 翻页看 PDF，打开续读上次页码，右上角投屏。
class ReaderPage extends StatefulWidget {
  final String path;
  final String name;
  const ReaderPage({super.key, required this.path, required this.name});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  PdfDoc? _doc;
  String? _error;
  PageController? _pc;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    CastSession.i.addListener(_onSession);
    _open();
  }

  void _onSession() {
    // 投屏主按钮的文案随会话状态切换
    if (mounted) setState(() {});
  }

  Future<void> _open() async {
    try {
      final doc = await PdfDoc.open(widget.path);
      final last =
          RecentStore.i.lastPageOf(widget.path).clamp(0, doc.pageCount - 1);
      await RecentStore.i
          .touch(widget.path, widget.name, pageCount: doc.pageCount);
      if (!mounted) {
        doc.dispose();
        return;
      }
      setState(() {
        _doc = doc;
        _page = last;
        _pc = PageController(initialPage: last);
      });
      ThumbCache.generate(doc);
    } catch (e) {
      if (mounted) setState(() => _error = '打开失败：$e');
    }
  }

  @override
  void dispose() {
    CastSession.i.removeListener(_onSession);
    _pc?.dispose();
    final doc = _doc;
    if (doc != null) {
      if (identical(CastSession.i.doc, doc)) {
        // 还在投屏，文档交给会话，停止投屏时再释放
        CastSession.i.ownsDoc = true;
      } else {
        doc.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _cast() async {
    final doc = _doc;
    if (doc == null) return;
    final session = CastSession.i;
    if (session.active && session.doc?.id != doc.id) {
      // 电视已连着，换文档直接投过去，不再弹设备面板（换设备入口在遥控页）
      try {
        await session.start(session.device!, doc, widget.name, _page);
      } catch (_) {
        // 直投失败（设备掉线等，会话已被拆掉），退回设备选择
      }
    }
    if (!mounted) return;
    if (!(session.active && session.doc?.id == doc.id)) {
      await showCastSheet(
        context,
        doc: doc,
        docName: widget.name,
        startPage: _page,
        onCasting: () {},
      );
    }
    if (!mounted) return;
    if (CastSession.i.active && CastSession.i.doc?.id == doc.id) {
      await Navigator.of(context).push(
        CupertinoPageRoute(builder: (_) => const RemotePage()),
      );
      // 从遥控页回来，本地跳到电视停留的页
      if (mounted && CastSession.i.doc != null) {
        final p = CastSession.i.page;
        _pc?.jumpToPage(p);
      }
    }
  }

  void _onPage(int p) {
    _page = p;
    RecentStore.i.setLastPage(widget.path, p);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGrey6,
      navigationBar: CupertinoNavigationBar(
        middle: Text(widget.name,
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      child: SafeArea(
        child: _error != null
            ? Center(child: Text(_error!))
            : doc == null
                ? const Center(child: CupertinoActivityIndicator())
                : Column(
                    children: [
                      Expanded(
                        child: PageView.builder(
                          controller: _pc,
                          onPageChanged: _onPage,
                          itemCount: doc.pageCount,
                          itemBuilder: (_, i) => _PageView(doc: doc, page: i),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          '${_page + 1} / ${doc.pageCount}',
                          style: const TextStyle(
                              fontSize: 13, color: CupertinoColors.systemGrey),
                        ),
                      ),
                      // 投屏是本 App 的核心动作，给显眼的主按钮
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                        child: SizedBox(
                          width: double.infinity,
                          child: CupertinoButton.filled(
                            onPressed: _cast,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(CupertinoIcons.tv, size: 20),
                                const SizedBox(width: 8),
                                Text(CastSession.i.active &&
                                        CastSession.i.doc?.id == doc.id
                                    ? '回到投屏遥控'
                                    : '投屏到电视'),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}

class _PageView extends StatelessWidget {
  final PdfDoc doc;
  final int page;
  const _PageView({required this.doc, required this.page});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: doc.renderPng(page, longEdge: 1600),
      builder: (_, snap) {
        if (snap.hasError) {
          return Center(child: Text('第 ${page + 1} 页加载失败'));
        }
        final bytes = snap.data;
        if (bytes == null) {
          return const Center(child: CupertinoActivityIndicator());
        }
        return InteractiveViewer(
          maxScale: 4,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Image.memory(bytes, gaplessPlayback: true),
            ),
          ),
        );
      },
    );
  }
}
