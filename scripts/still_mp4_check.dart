// 本地校验纯 Dart 编码器：test.rgba(1920x1080) → still.mp4，供 ffprobe/ffmpeg 验证
import 'dart:io';

import 'package:pdfcast/serve/still_mp4.dart';

Future<void> main(List<String> args) async {
  final rgba = await File('build/probe/test.rgba').readAsBytes();
  final sw = Stopwatch()..start();
  final mp4 = encodeStillMp4(
      rgba: rgba, width: 1920, height: 1080, holdSeconds: 30);
  print('encoded in ${sw.elapsedMilliseconds}ms, ${mp4.length} bytes');
  await File('build/probe/still.mp4').writeAsBytes(mp4);
}
