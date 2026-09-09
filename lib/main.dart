import 'package:flutter/cupertino.dart';

import 'library/library_page.dart';
import 'share/share_receiver.dart';

void main() {
  runApp(const PdfCastApp());
}

class PdfCastApp extends StatefulWidget {
  const PdfCastApp({super.key});

  @override
  State<PdfCastApp> createState() => _PdfCastAppState();
}

class _PdfCastAppState extends State<PdfCastApp> {
  final _libraryKey = GlobalKey<LibraryPageState>();
  final _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    ShareReceiver.listen(_onSharedPdf);
  }

  void _onSharedPdf(String path) {
    // 收到分享：回到文件库再打开，避免叠一摞阅读页
    _navKey.currentState?.popUntil((r) => r.isFirst);
    _libraryKey.currentState?.openPdf(path);
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      title: 'PDF 投屏',
      navigatorKey: _navKey,
      debugShowCheckedModeBanner: false,
      theme: const CupertinoThemeData(
        brightness: Brightness.light,
        primaryColor: CupertinoColors.activeBlue,
      ),
      home: LibraryPage(key: _libraryKey),
    );
  }
}
