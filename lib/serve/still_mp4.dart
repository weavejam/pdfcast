// 纯 Dart 把一张 RGBA 静态图编码成 H.264 MP4（无任何原生依赖）。
// 原理：电视 DLNA renderer（stagefright）无视图片投屏但稳定播 H.264/MP4，
// 所以每页 PDF 编成"一帧 I_PCM(无压缩宏块) + 大量 P_Skip(重复上一帧)"的长视频。
// I_PCM 不需要 DCT/熵编码，P_Skip 每帧仅约 10 字节，全程只有比特级封装。
import 'dart:typed_data';

/// [rgba] 为 width*height*4 的 RGBA 像素；[holdSeconds] 是画面保持时长（1fps 重复帧）。
Uint8List encodeStillMp4({
  required Uint8List rgba,
  required int width,
  required int height,
  int holdSeconds = 3600,
}) {
  assert(rgba.length >= width * height * 4);
  final padW = (width + 15) & ~15;
  final padH = (height + 15) & ~15;
  // 裁剪偏移以 2 像素为单位（4:2:0），奇数尺寸时多显示 1 列/行的边缘复制像素，肉眼不可见
  final dispW = width & ~1;
  final dispH = height & ~1;

  final yuv = _rgbaToYuv420(rgba, width, height, padW, padH);
  final sps = _buildSps(padW, padH, dispW, dispH);
  final pps = _buildPps();
  final idr = _buildIdrSlice(yuv, padW, padH);
  final frames = <Uint8List>[idr];
  final totalMbs = (padW ~/ 16) * (padH ~/ 16);
  for (var i = 1; i < holdSeconds; i++) {
    frames.add(_buildPSkipSlice(i, totalMbs));
  }
  return _muxMp4(sps, pps, frames, dispW, dispH);
}

// ---------- 色彩转换：RGBA → YUV420 limited range BT.601 ----------
class _Yuv {
  final Uint8List y, cb, cr;
  _Yuv(this.y, this.cb, this.cr);
}

_Yuv _rgbaToYuv420(Uint8List rgba, int w, int h, int padW, int padH) {
  final y = Uint8List(padW * padH);
  final cb = Uint8List(padW * padH ~/ 4);
  final cr = Uint8List(padW * padH ~/ 4);
  final cbSum = Int32List(padW * padH ~/ 4);
  final crSum = Int32List(padW * padH ~/ 4);
  final halfW = padW ~/ 2;
  for (var py = 0; py < padH; py++) {
    final sy = py < h ? py : h - 1; // 边缘复制填充
    for (var px = 0; px < padW; px++) {
      final sx = px < w ? px : w - 1;
      final o = (sy * w + sx) * 4;
      final r = rgba[o], g = rgba[o + 1], b = rgba[o + 2];
      y[py * padW + px] = (((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
      final ci = (py >> 1) * halfW + (px >> 1);
      cbSum[ci] += ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
      crSum[ci] += ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
    }
  }
  for (var i = 0; i < cb.length; i++) {
    cb[i] = ((cbSum[i] + 2) >> 2).clamp(16, 240);
    cr[i] = ((crSum[i] + 2) >> 2).clamp(16, 240);
  }
  return _Yuv(y, cb, cr);
}

// ---------- 比特流写入 ----------
class _BitWriter {
  final BytesBuilder _out = BytesBuilder();
  int _cur = 0, _nbits = 0;

  void bit(int b) {
    _cur = (_cur << 1) | (b & 1);
    if (++_nbits == 8) {
      _out.addByte(_cur);
      _cur = 0;
      _nbits = 0;
    }
  }

  void bits(int value, int n) {
    for (var i = n - 1; i >= 0; i--) {
      bit((value >> i) & 1);
    }
  }

  void ue(int v) {
    final code = v + 1;
    var len = 0;
    for (var t = code; t > 1; t >>= 1) {
      len++;
    }
    bits(0, len);
    bits(code, len + 1);
  }

  void se(int v) => ue(v <= 0 ? -2 * v : 2 * v - 1);

  bool get aligned => _nbits == 0;

  void alignZero() {
    while (_nbits != 0) {
      bit(0);
    }
  }

  void bytesAligned(Uint8List data) {
    assert(_nbits == 0);
    _out.add(data);
  }

  /// rbsp_trailing_bits：stop bit + 补零对齐
  Uint8List finishRbsp() {
    bit(1);
    alignZero();
    return _out.toBytes();
  }
}

/// RBSP → EBSP：连续两个 0x00 后跟 <=0x03 时插入 0x03（emulation prevention）
Uint8List _nal(int headerByte, Uint8List rbsp) {
  final out = BytesBuilder();
  out.addByte(headerByte);
  var zeros = 0;
  for (final b in rbsp) {
    if (zeros >= 2 && b <= 3) {
      out.addByte(3);
      zeros = 0;
    }
    out.addByte(b);
    zeros = b == 0 ? zeros + 1 : 0;
  }
  return out.toBytes();
}

// ---------- H.264 语法元素 ----------
const _profileIdc = 66; // Baseline
const _constraintFlags = 0xC0; // constraint_set0 + set1
const _levelIdc = 42; // 1080p 单帧 3MB 峰值码率需要 4.2

Uint8List _buildSps(int padW, int padH, int dispW, int dispH) {
  final w = _BitWriter();
  w.bits(_profileIdc, 8);
  w.bits(_constraintFlags, 8);
  w.bits(_levelIdc, 8);
  w.ue(0); // seq_parameter_set_id
  w.ue(12); // log2_max_frame_num_minus4 → frame_num 16bit
  w.ue(2); // pic_order_cnt_type = 2（解码序即显示序，无 POC 字段）
  w.ue(1); // max_num_ref_frames
  w.bit(0); // gaps_in_frame_num_value_allowed
  w.ue(padW ~/ 16 - 1);
  w.ue(padH ~/ 16 - 1);
  w.bit(1); // frame_mbs_only
  w.bit(1); // direct_8x8_inference
  final crop = padW != dispW || padH != dispH;
  w.bit(crop ? 1 : 0);
  if (crop) {
    w.ue(0);
    w.ue((padW - dispW) ~/ 2);
    w.ue(0);
    w.ue((padH - dispH) ~/ 2);
  }
  w.bit(0); // vui_parameters_present
  return _nal(0x67, w.finishRbsp());
}

Uint8List _buildPps() {
  final w = _BitWriter();
  w.ue(0); // pps_id
  w.ue(0); // sps_id
  w.bit(0); // entropy_coding_mode = CAVLC
  w.bit(0); // bottom_field_pic_order_in_frame_present
  w.ue(0); // num_slice_groups_minus1
  w.ue(0); // num_ref_idx_l0_default_active_minus1
  w.ue(0); // num_ref_idx_l1_default_active_minus1
  w.bit(0); // weighted_pred
  w.bits(0, 2); // weighted_bipred_idc
  w.se(0); // pic_init_qp_minus26
  w.se(0); // pic_init_qs_minus26
  w.se(0); // chroma_qp_index_offset
  w.bit(0); // deblocking_filter_control_present
  w.bit(0); // constrained_intra_pred
  w.bit(0); // redundant_pic_cnt_present
  return _nal(0x68, w.finishRbsp());
}

/// IDR 帧：所有宏块 I_PCM（裸 YUV 字节，无压缩）。
/// 对齐规律：slice header 后第一个宏块做一次 pcm 对齐，之后每宏块
/// mb_type ue(25)=9bit + 7bit 对齐 = 16bit，恒保持字节对齐 → 可整块写入。
Uint8List _buildIdrSlice(_Yuv yuv, int padW, int padH) {
  final w = _BitWriter();
  w.ue(0); // first_mb_in_slice
  w.ue(7); // slice_type = I (all)
  w.ue(0); // pps_id
  w.bits(0, 16); // frame_num
  w.ue(0); // idr_pic_id
  w.bit(0); // no_output_of_prior_pics
  w.bit(0); // long_term_reference
  w.se(0); // slice_qp_delta

  final mbW = padW ~/ 16, mbH = padH ~/ 16;
  final halfW = padW ~/ 2;
  final mb = Uint8List(384);
  for (var my = 0; my < mbH; my++) {
    for (var mx = 0; mx < mbW; mx++) {
      w.ue(25); // mb_type = I_PCM
      w.alignZero(); // pcm_alignment_zero_bit
      var p = 0;
      final yBase = my * 16 * padW + mx * 16;
      for (var r = 0; r < 16; r++) {
        final row = yBase + r * padW;
        for (var c = 0; c < 16; c++) {
          mb[p++] = yuv.y[row + c];
        }
      }
      final cBase = my * 8 * halfW + mx * 8;
      for (var r = 0; r < 8; r++) {
        final row = cBase + r * halfW;
        for (var c = 0; c < 8; c++) {
          mb[p++] = yuv.cb[row + c];
        }
      }
      for (var r = 0; r < 8; r++) {
        final row = cBase + r * halfW;
        for (var c = 0; c < 8; c++) {
          mb[p++] = yuv.cr[row + c];
        }
      }
      w.bytesAligned(mb);
    }
  }
  return _nal(0x65, w.finishRbsp());
}

/// P 帧：整帧 mb_skip_run，直接复制参考帧 → 画面保持不动
Uint8List _buildPSkipSlice(int frameIdx, int totalMbs) {
  final w = _BitWriter();
  w.ue(0); // first_mb_in_slice
  w.ue(5); // slice_type = P (all)
  w.ue(0); // pps_id
  w.bits(frameIdx & 0xFFFF, 16); // frame_num
  w.bit(0); // num_ref_idx_active_override
  w.bit(0); // ref_pic_list_modification_flag_l0
  w.bit(0); // adaptive_ref_pic_marking_mode
  w.se(0); // slice_qp_delta
  w.ue(totalMbs); // mb_skip_run：全部跳过
  return _nal(0x41, w.finishRbsp());
}

// ---------- MP4 封装 ----------
Uint8List _u32(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v);
Uint8List _u16(int v) =>
    Uint8List(2)..buffer.asByteData().setUint16(0, v);

Uint8List _box(String type, List<List<int>> children) {
  final body = BytesBuilder();
  for (final c in children) {
    body.add(c);
  }
  final b = BytesBuilder()
    ..add(_u32(8 + body.length))
    ..add(type.codeUnits)
    ..add(body.toBytes());
  return b.toBytes();
}

Uint8List _muxMp4(
    Uint8List sps, Uint8List pps, List<Uint8List> frames, int w, int h) {
  const timescale = 1000;
  const sampleDelta = 1000; // 1fps
  final n = frames.length;
  final duration = n * sampleDelta;

  final ftyp = _box('ftyp', [
    'isom'.codeUnits,
    _u32(512),
    'isomiso2avc1mp41'.codeUnits,
  ]);

  Uint8List moovFor(int chunkOffset) {
    final mvhd = _box('mvhd', [
      _u32(0), // version+flags
      _u32(0), _u32(0), // times
      _u32(timescale), _u32(duration),
      _u32(0x00010000), _u16(0x0100), _u16(0), _u32(0), _u32(0),
      _u32(0x00010000), _u32(0), _u32(0), _u32(0), _u32(0x00010000),
      _u32(0), _u32(0), _u32(0), _u32(0x40000000),
      Uint8List(24), // pre_defined
      _u32(2), // next_track_id
    ]);
    final tkhd = _box('tkhd', [
      _u32(3), // version=0 flags=enabled|in_movie
      _u32(0), _u32(0),
      _u32(1), // track_id
      _u32(0), _u32(duration),
      Uint8List(8), _u16(0), _u16(0), _u16(0), _u16(0),
      _u32(0x00010000), _u32(0), _u32(0), _u32(0), _u32(0x00010000),
      _u32(0), _u32(0), _u32(0), _u32(0x40000000),
      _u32(w << 16), _u32(h << 16),
    ]);
    final mdhd = _box('mdhd', [
      _u32(0), _u32(0), _u32(0),
      _u32(timescale), _u32(duration),
      _u16(0x55C4), _u16(0), // language und
    ]);
    final hdlr = _box('hdlr', [
      _u32(0), _u32(0),
      'vide'.codeUnits,
      Uint8List(12),
      'pdfcast\x00'.codeUnits,
    ]);
    final avcC = _box('avcC', [
      [1, _profileIdc, _constraintFlags, _levelIdc, 0xFF, 0xE1],
      _u16(sps.length), sps,
      [1],
      _u16(pps.length), pps,
    ]);
    final avc1 = _box('avc1', [
      Uint8List(6), _u16(1), // data_reference_index
      Uint8List(16), // pre_defined/reserved
      _u16(w), _u16(h),
      _u32(0x00480000), _u32(0x00480000), _u32(0),
      _u16(1), // frame_count
      Uint8List(32), // compressorname
      _u16(24), _u16(0xFFFF),
      avcC,
    ]);
    final stsd = _box('stsd', [_u32(0), _u32(1), avc1]);
    final stts = _box('stts', [_u32(0), _u32(1), _u32(n), _u32(sampleDelta)]);
    final stss = _box('stss', [_u32(0), _u32(1), _u32(1)]);
    final stsc = _box('stsc', [_u32(0), _u32(1), _u32(1), _u32(n), _u32(1)]);
    final stszBody = BytesBuilder()
      ..add(_u32(0))
      ..add(_u32(0))
      ..add(_u32(n));
    for (final f in frames) {
      stszBody.add(_u32(4 + f.length));
    }
    final stsz = _box('stsz', [stszBody.toBytes()]);
    final stco = _box('stco', [_u32(0), _u32(1), _u32(chunkOffset)]);
    final stbl = _box('stbl', [stsd, stts, stss, stsc, stsz, stco]);
    final vmhd = _box('vmhd', [_u32(1), Uint8List(8)]);
    final dref = _box('dref', [_u32(0), _u32(1), _box('url ', [_u32(1)])]);
    final dinf = _box('dinf', [dref]);
    final minf = _box('minf', [vmhd, dinf, stbl]);
    final mdia = _box('mdia', [mdhd, hdlr, minf]);
    final trak = _box('trak', [tkhd, mdia]);
    return _box('moov', [mvhd, trak]);
  }

  final moovLen = moovFor(0).length;
  final moov = moovFor(ftyp.length + moovLen + 8); // +8 = mdat header

  final mdat = BytesBuilder();
  for (final f in frames) {
    mdat.add(_u32(f.length));
    mdat.add(f);
  }

  final out = BytesBuilder()
    ..add(ftyp)
    ..add(moov)
    ..add(_box('mdat', [mdat.toBytes()]));
  return out.toBytes();
}
