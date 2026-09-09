import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';

import '../pdf/thumb_cache.dart';
import '../reader/reader_page.dart';
import 'recent_store.dart';

/// 首页文件库：最近文件网格（封面 = 首页缩略图）+ 导入按钮
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => LibraryPageState();
}

class LibraryPageState extends State<LibraryPage> {
  List<RecentEntry> _entries = const [];
  bool _loading = true;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final list = await RecentStore.i.load();
    if (!mounted) return;
    setState(() {
      _entries = list;
      _loading = false;
    });
  }

  Future<void> _import() async {
    if (_importing) return;
    setState(() => _importing = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      final src = result?.files.single.path;
      if (src == null) return;
      await openPdf(src);
    } catch (e) {
      if (mounted) _alert('导入失败', '$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 打开一个 PDF（外部路径会先拷入 app 目录），进阅读页。
  /// 分享接收也走这个入口。
  Future<void> openPdf(String srcPath, {String? preferredName}) async {
    final path = await RecentStore.i.importFile(srcPath,
        preferredName: preferredName);
    final name = path.split(Platform.pathSeparator).last;
    if (!mounted) return;
    await Navigator.of(context).push(
      CupertinoPageRoute(builder: (_) => ReaderPage(path: path, name: name)),
    );
    _refresh();
  }

  Future<void> _open(RecentEntry e) async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
          builder: (_) => ReaderPage(path: e.path, name: e.name)),
    );
    _refresh();
  }

  void _showActions(RecentEntry e) {
    showCupertinoModalPopup(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: Text(e.name),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () async {
              Navigator.pop(ctx);
              await RecentStore.i.remove(e.path, deleteFile: true);
              _refresh();
            },
            child: const Text('删除'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
      ),
    );
  }

  void _alert(String title, String msg) {
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(msg),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('好'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('PDF 投屏'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _import,
          child: _importing
              ? const CupertinoActivityIndicator()
              : const Icon(CupertinoIcons.add),
        ),
      ),
      child: SafeArea(
        child: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : _entries.isEmpty
                ? _empty()
                : GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 160,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      childAspectRatio: 0.62,
                    ),
                    itemCount: _entries.length,
                    itemBuilder: (_, i) => _tile(_entries[i]),
                  ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(CupertinoIcons.doc_text,
              size: 56, color: CupertinoColors.systemGrey2),
          const SizedBox(height: 12),
          const Text('还没有 PDF',
              style: TextStyle(color: CupertinoColors.systemGrey)),
          const SizedBox(height: 4),
          const Text('点右上角 + 导入，或从其他 App 分享 PDF 过来',
              style:
                  TextStyle(fontSize: 13, color: CupertinoColors.systemGrey2)),
          const SizedBox(height: 16),
          CupertinoButton.filled(
            onPressed: _import,
            child: const Text('导入 PDF'),
          ),
        ],
      ),
    );
  }

  Widget _tile(RecentEntry e) {
    final progress = e.pageCount > 0
        ? (e.lastPage > 0 ? '读到 ${e.lastPage + 1}/${e.pageCount} 页' : '共 ${e.pageCount} 页')
        : '';
    return GestureDetector(
      onTap: () => _open(e),
      onLongPress: () => _showActions(e),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey6,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: CupertinoColors.systemGrey5),
              ),
              child: FutureBuilder<File?>(
                future: ThumbCache.fileFor(e.path),
                builder: (_, snap) {
                  final f = snap.data;
                  if (f == null) {
                    return const Center(
                      child: Icon(CupertinoIcons.doc_text,
                          size: 40, color: CupertinoColors.systemGrey3),
                    );
                  }
                  return Image.file(f, fit: BoxFit.cover);
                },
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            e.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
          if (progress.isNotEmpty)
            Text(
              progress,
              style: const TextStyle(
                  fontSize: 11, color: CupertinoColors.systemGrey),
            ),
        ],
      ),
    );
  }
}
