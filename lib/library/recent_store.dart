import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条最近文件记录
class RecentEntry {
  final String path;
  final String name;
  final int lastPage;
  final int pageCount;
  final int openedAt; // ms since epoch

  RecentEntry({
    required this.path,
    required this.name,
    this.lastPage = 0,
    this.pageCount = 0,
    required this.openedAt,
  });

  RecentEntry copyWith({int? lastPage, int? pageCount, int? openedAt}) =>
      RecentEntry(
        path: path,
        name: name,
        lastPage: lastPage ?? this.lastPage,
        pageCount: pageCount ?? this.pageCount,
        openedAt: openedAt ?? this.openedAt,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'name': name,
        'lastPage': lastPage,
        'pageCount': pageCount,
        'openedAt': openedAt,
      };

  static RecentEntry fromJson(Map<String, dynamic> j) => RecentEntry(
        path: j['path'] as String,
        name: j['name'] as String,
        lastPage: (j['lastPage'] as num?)?.toInt() ?? 0,
        pageCount: (j['pageCount'] as num?)?.toInt() ?? 0,
        openedAt: (j['openedAt'] as num?)?.toInt() ?? 0,
      );
}

/// 最近文件与续读页码（shared_preferences 持久化）。
/// 导入的 PDF 统一拷贝到 app 文档目录 /pdfs/ 下，来源文件删了也不受影响。
class RecentStore {
  RecentStore._();
  static final RecentStore i = RecentStore._();

  static const _key = 'recent_files';
  List<RecentEntry> _entries = [];
  bool _loaded = false;

  Future<List<RecentEntry>> load() async {
    if (!_loaded) {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_key);
      if (raw != null) {
        try {
          _entries = (jsonDecode(raw) as List)
              .map((e) => RecentEntry.fromJson(e as Map<String, dynamic>))
              .toList();
        } catch (_) {
          _entries = [];
        }
      }
      _loaded = true;
    }
    // 清掉磁盘上已不存在的文件
    _entries.removeWhere((e) => !File(e.path).existsSync());
    return List.unmodifiable(_entries);
  }

  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
        _key, jsonEncode(_entries.map((e) => e.toJson()).toList()));
  }

  /// 把外部 PDF 拷进 app 私有目录，返回内部路径。
  /// 同名文件已存在且大小一致时直接复用，避免重复导入占空间。
  Future<String> importFile(String srcPath, {String? preferredName}) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}pdfs');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    var name = preferredName ?? srcPath.split(RegExp(r'[\\/]')).last;
    if (!name.toLowerCase().endsWith('.pdf')) name = '$name.pdf';
    final src = File(srcPath);
    var dst = File('${dir.path}${Platform.pathSeparator}$name');
    if (dst.existsSync()) {
      if (dst.lengthSync() == src.lengthSync()) return dst.path;
      final base = name.substring(0, name.length - 4);
      var n = 2;
      while (dst.existsSync() && dst.lengthSync() != src.lengthSync()) {
        dst = File('${dir.path}${Platform.pathSeparator}$base($n).pdf');
        n++;
      }
      if (dst.existsSync()) return dst.path;
    }
    await src.copy(dst.path);
    return dst.path;
  }

  Future<void> touch(String path, String name, {int? pageCount}) async {
    await load();
    final now = DateTime.now().millisecondsSinceEpoch;
    final idx = _entries.indexWhere((e) => e.path == path);
    if (idx >= 0) {
      _entries[idx] = _entries[idx]
          .copyWith(openedAt: now, pageCount: pageCount);
    } else {
      _entries.add(RecentEntry(
        path: path,
        name: name,
        pageCount: pageCount ?? 0,
        openedAt: now,
      ));
    }
    _entries.sort((a, b) => b.openedAt.compareTo(a.openedAt));
    await _save();
  }

  Future<void> setLastPage(String path, int page) async {
    await load();
    final idx = _entries.indexWhere((e) => e.path == path);
    if (idx < 0) return;
    if (_entries[idx].lastPage == page) return;
    _entries[idx] = _entries[idx].copyWith(lastPage: page);
    await _save();
  }

  int lastPageOf(String path) {
    final idx = _entries.indexWhere((e) => e.path == path);
    return idx >= 0 ? _entries[idx].lastPage : 0;
  }

  Future<void> remove(String path, {bool deleteFile = false}) async {
    await load();
    _entries.removeWhere((e) => e.path == path);
    await _save();
    if (deleteFile) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
  }
}
