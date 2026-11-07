import 'dart:io';
import 'dart:typed_data';

/// Иконки внутри IPA сохранены Xcode в «оптимизированном для iPhone» PNG (чанк CgBI):
/// пиксели в порядке BGRA с предумноженной альфой, IDAT — сырой deflate без заголовка zlib.
/// Обычные декодеры такие файлы не читают — перекодируем в стандартный PNG.
class PngDecoder {
  static const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

  static bool isPng(Uint8List d) => d.length > 8 && _startsWith(d, signature);

  /// Первый чанк после сигнатуры называется CgBI.
  static bool isCgBI(Uint8List d) =>
      d.length >= 16 && _startsWith(d, signature) && d[12] == 0x43 && d[13] == 0x67 && d[14] == 0x42 && d[15] == 0x49;

  /// Обычный PNG — как есть, CgBI — перекодированный; остальное — `null`.
  static Uint8List? normalize(Uint8List data) {
    if (isCgBI(data)) return decodeCgBI(data);
    return isPng(data) ? data : null;
  }

  static Uint8List? decodeCgBI(Uint8List bytes) {
    var width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0;
    final idat = BytesBuilder(copy: false);
    var cgbi = false;
    var pos = 8;
    while (pos + 8 <= bytes.length) {
      final length = _be32(bytes, pos);
      final type = String.fromCharCodes(bytes.sublist(pos + 4, pos + 8));
      final start = pos + 8, end = start + length;
      if (end > bytes.length) break;
      if (type == 'CgBI') {
        cgbi = true;
      } else if (type == 'IHDR' && length >= 13) {
        width = _be32(bytes, start);
        height = _be32(bytes, start + 4);
        bitDepth = bytes[start + 8];
        colorType = bytes[start + 9];
        interlace = bytes[start + 12];
      } else if (type == 'IDAT') {
        idat.add(bytes.sublist(start, end));
      } else if (type == 'IEND') {
        break;
      }
      pos = end + 4; // + CRC
    }
    if (!cgbi || width <= 0 || height <= 0 || width > 8192 || height > 8192 || bitDepth != 8 || interlace != 0) return null;
    if (colorType != 6 && colorType != 2) return null;

    final channels = colorType == 6 ? 4 : 3;
    final expected = height * (width * channels + 1);
    final raw = _inflate(idat.takeBytes(), expected);
    if (raw == null) return null;
    final pixels = _unfilter(raw, width, height, channels);
    if (pixels == null) return null;

    // BGR(A) с предумноженной альфой → RGBA с обычной.
    final rgba = Uint8List(width * height * 4);
    for (var i = 0; i < width * height; i++) {
      final s = i * channels, d = i * 4;
      final a = channels == 4 ? pixels[s + 3] : 255;
      int un(int c) => a == 0 ? 0 : (a == 255 ? c : ((c * 255 + a ~/ 2) ~/ a).clamp(0, 255));
      rgba[d] = un(pixels[s + 2]);
      rgba[d + 1] = un(pixels[s + 1]);
      rgba[d + 2] = un(pixels[s]);
      rgba[d + 3] = a;
    }
    return encodeRGBA(width, height, rgba);
  }

  /// Сырой deflate; встречаются файлы с обычным заголовком zlib — тогда пробуем как zlib.
  static Uint8List? _inflate(Uint8List src, int expected) {
    Uint8List? decode(ZLibDecoder decoder) {
      try {
        final out = decoder.convert(src);
        return out.length >= expected ? Uint8List.fromList(out.sublist(0, expected)) : null;
      } catch (_) {
        return null;
      }
    }

    return decode(ZLibDecoder(raw: true)) ?? decode(ZLibDecoder());
  }

  /// Снятие построчных фильтров PNG (None, Sub, Up, Average, Paeth).
  static Uint8List? _unfilter(Uint8List raw, int width, int height, int channels) {
    final stride = width * channels;
    final out = Uint8List(height * stride);
    for (var y = 0; y < height; y++) {
      final src = y * (stride + 1);
      final filter = raw[src];
      final row = y * stride, prev = row - stride;
      for (var x = 0; x < stride; x++) {
        final v = raw[src + 1 + x];
        final a = x >= channels ? out[row + x - channels] : 0;
        final b = y > 0 ? out[prev + x] : 0;
        final c = (x >= channels && y > 0) ? out[prev + x - channels] : 0;
        final int predictor;
        switch (filter) {
          case 0:
            predictor = 0;
          case 1:
            predictor = a;
          case 2:
            predictor = b;
          case 3:
            predictor = (a + b) ~/ 2;
          case 4:
            final p = a + b - c;
            final pa = (p - a).abs(), pb = (p - b).abs(), pc = (p - c).abs();
            predictor = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
          default:
            return null;
        }
        out[row + x] = (v + predictor) & 0xFF;
      }
    }
    return out;
  }

  static Uint8List encodeRGBA(int width, int height, Uint8List rgba) {
    final stride = width * 4;
    final raw = Uint8List(height * (stride + 1));
    for (var y = 0; y < height; y++) {
      raw.setRange(y * (stride + 1) + 1, (y + 1) * (stride + 1), rgba, y * stride);
    }
    final ihdr = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 8)
      ..setUint8(9, 6);
    final out = BytesBuilder(copy: false)
      ..add(signature)
      ..add(_chunk('IHDR', ihdr.buffer.asUint8List()))
      ..add(_chunk('IDAT', Uint8List.fromList(ZLibEncoder(level: 6).convert(raw))))
      ..add(_chunk('IEND', Uint8List(0)));
    return out.takeBytes();
  }

  static Uint8List _chunk(String type, Uint8List data) {
    final typed = Uint8List.fromList([...type.codeUnits, ...data]);
    final b = ByteData(12 + data.length)..setUint32(0, data.length);
    final out = b.buffer.asUint8List()..setRange(4, 8 + data.length, typed);
    ByteData.sublistView(out).setUint32(8 + data.length, crc32(typed));
    return out;
  }

  static final _crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });

  static int crc32(List<int> data) {
    var c = 0xFFFFFFFF;
    for (final b in data) {
      c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
  }

  static int _be32(Uint8List b, int o) => b[o] << 24 | b[o + 1] << 16 | b[o + 2] << 8 | b[o + 3];

  static bool _startsWith(Uint8List d, List<int> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (d[i] != prefix[i]) return false;
    }
    return true;
  }
}
