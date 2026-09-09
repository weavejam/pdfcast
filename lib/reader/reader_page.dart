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
    _open();
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
    await showCastSheet(
      context,
      doc: doc,
      docName: widget.name,
      startPage: _page,
      onCasting: () {},
    );
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
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: doc == null ? null : _cast,
          child: const Icon(CupertinoIcons.tv),
        ),
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
