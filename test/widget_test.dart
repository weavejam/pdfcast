import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcast/library/recent_store.dart';

void main() {
  test('RecentEntry json 往返', () {
    final e = RecentEntry(
      path: r'C:\docs\a.pdf',
      name: 'a.pdf',
      lastPage: 5,
      pageCount: 42,
      openedAt: 1700000000000,
    );
    final back = RecentEntry.fromJson(e.toJson());
    expect(back.path, e.path);
    expect(back.name, e.name);
    expect(back.lastPage, 5);
    expect(back.pageCount, 42);
    expect(back.openedAt, e.openedAt);
  });

  test('copyWith 只改指定字段', () {
    final e = RecentEntry(path: 'p', name: 'n', openedAt: 1);
    final c = e.copyWith(lastPage: 3);
    expect(c.lastPage, 3);
    expect(c.path, 'p');
    expect(c.pageCount, 0);
    expect(c.openedAt, 1);
  });
}
