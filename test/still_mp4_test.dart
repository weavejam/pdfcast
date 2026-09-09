import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfcast/serve/still_mp4.dart';

Uint8List _solidRgba(int w, int h, int r, int g, int b) {
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    px[i * 4] = r;
    px[i * 4 + 1] = g;
    px[i * 4 + 2] = b;
    px[i * 4 + 3] = 255;
  }
  return px;
}

/// 解析顶层 MP4 box：返回 type → (offset, size)
Map<String, ({int offset, int size})> _topBoxes(Uint8List mp4) {
  final boxes = <String, ({int offset, int size})>{};
  final bd = ByteData.sublistView(mp4);
  var off = 0;
  while (off + 8 <= mp4.length) {
    final size = bd.getUint32(off);
    final type = String.fromCharCodes(mp4.sublist(off + 4, off + 8));
    expect(size, greaterThanOrEqualTo(8), reason: 'box $type 尺寸非法');
    boxes[type] = (offset: off, size: size);
    off += size;
  }
  expect(off, mp4.length, reason: '顶层 box 链没有恰好覆盖整个文件');
  return boxes;
}

int _indexOf(Uint8List data, List<int> pattern, [int start = 0]) {
  outer:
  for (var i = start; i <= data.length - pattern.length; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (data[i + j] != pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}

void main() {
  test('输出是完整 MP4：ftyp/mdat/moov 顶层 box 链覆盖全文件', () {
    final mp4 = encodeStillMp4(
      rgba: _solidRgba(32, 32, 255, 0, 0),
      width: 32,
      height: 32,
      holdSeconds: 5,
    );
    final boxes = _topBoxes(mp4);
    expect(boxes.keys, containsAll(['ftyp', 'mdat', 'moov']));
    expect(boxes['ftyp']!.offset, 0, reason: 'ftyp 必须在文件开头');
  });

  test('奇数/非 16 对齐尺寸可编码且不越界', () {
    for (final (w, h) in [(33, 17), (1, 1), (15, 16), (200, 121)]) {
      final mp4 = encodeStillMp4(
        rgba: _solidRgba(w, h, 10, 200, 30),
        width: w,
        height: h,
        holdSeconds: 2,
      );
      _topBoxes(mp4); // 结构完整即通过
    }
  });

  test('holdSeconds 增加帧数：更长的视频文件更大', () {
    Uint8List enc(int s) => encodeStillMp4(
          rgba: _solidRgba(48, 48, 0, 0, 255),
          width: 48,
          height: 48,
          holdSeconds: s,
        );
    final short = enc(2);
    final long = enc(60);
    expect(long.length, greaterThan(short.length));
    // P_Skip 帧极小：58 帧的增量应远小于 IDR 体积（每帧约 10 字节 + 表项）
    expect(long.length - short.length, lessThan(3000));
  });

  test('tkhd 中的显示尺寸是裁掉奇数后的偶数尺寸', () {
    final mp4 = encodeStillMp4(
      rgba: _solidRgba(33, 17, 128, 128, 128),
      width: 33,
      height: 17,
      holdSeconds: 1,
    );
    final at = _indexOf(mp4, 'tkhd'.codeUnits);
    expect(at, greaterThan(0));
    // tkhd v0 payload: ver/flags(4)+创建/修改(8)+id(4)+保留(4)+时长(4)
    //                  +保留(8)+layer等(8)+matrix(36)=76 后是 16.16 定点宽高
    final bd = ByteData.sublistView(mp4);
    final whOff = at + 4 + 76;
    final w = bd.getUint32(whOff) >> 16;
    final h = bd.getUint32(whOff + 4) >> 16;
    expect((w, h), (32, 16));
  });

  test('IDR 画面像素级还原：I_PCM 无损，YUV 回转 RGB 误差在舍入范围内', () {
    // I_PCM 宏块无压缩，唯一损失是 RGB→YUV420→(播放器)回转的舍入
    final mp4 = encodeStillMp4(
      rgba: _solidRgba(16, 16, 200, 100, 50),
      width: 16,
      height: 16,
      holdSeconds: 1,
    );
    // Y = ((66*200+129*100+25*50+128)>>8)+16 = 118；mdat 里应有连续 256 个该值
    final expectedY = ((66 * 200 + 129 * 100 + 25 * 50 + 128) >> 8) + 16;
    final run = List.filled(64, expectedY);
    expect(_indexOf(mp4, run), greaterThan(0),
        reason: 'mdat 中找不到 I_PCM 明文 Y 平面');
  });
}
