import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' show ArchiveFile, InputFileStream, ZipFileEncoder;
import 'package:path/path.dart' as p;

import 'macho.dart';

class ZipEntry {
  ZipEntry({
    required this.name,
    required this.method,
    required this.compressedSize,
    required this.size,
    required this.localOffset,
    required this.madeBy,
    required this.externalAttributes,
  });

  final String name;
  final int method;
  final int compressedSize;
  final int size;
  final int localOffset;
  final int madeBy;
  final int externalAttributes;

  bool get isDirectory => name.endsWith('/');
  bool get _unix => (madeBy >> 8) == 3;
  int get unixMode => _unix ? (externalAttributes >> 16) & 0xFFFF : 0;
  bool get isSymlink => (unixMode & 0xF000) == 0xA000;
}

class ZipException implements Exception {
  ZipException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Чтение zip без распаковки целиком: оглавление, отдельные записи, начало большой записи.
/// IPA бывают по несколько гигабайт — данные читаются кусками и разжимаются потоково.
class ZipReader {
  ZipReader._(this.path, this.entries) : _byName = {for (final e in entries) e.name: e};

  final String path;
  final List<ZipEntry> entries;
  final Map<String, ZipEntry> _byName;

  ZipEntry? operator [](String name) => _byName[name];
  Iterable<String> get names => entries.map((e) => e.name);

  static Future<ZipReader> open(String path) async {
    final raf = await File(path).open();
    try {
      final (cdOffset, cdSize, count) = await _centralDirectory(raf);
      await raf.setPosition(cdOffset);
      final cd = await raf.read(cdSize);
      final bd = ByteData.sublistView(cd);
      final entries = <ZipEntry>[];
      var at = 0;
      for (var i = 0; i < count && at + 46 <= cd.length; i++) {
        if (bd.getUint32(at, Endian.little) != 0x02014b50) throw ZipException('повреждено оглавление zip');
        final nameLen = bd.getUint16(at + 28, Endian.little);
        final extraLen = bd.getUint16(at + 30, Endian.little);
        final commentLen = bd.getUint16(at + 32, Endian.little);
        var compressed = bd.getUint32(at + 20, Endian.little);
        var size = bd.getUint32(at + 24, Endian.little);
        var offset = bd.getUint32(at + 42, Endian.little);
        final name = utf8.decode(cd.sublist(at + 46, at + 46 + nameLen), allowMalformed: true);
        // Zip64: поля, равные 0xFFFFFFFF, лежат в дополнительном блоке 0x0001 — в этом порядке.
        var x = at + 46 + nameLen;
        final extraEnd = x + extraLen;
        while (x + 4 <= extraEnd) {
          final id = bd.getUint16(x, Endian.little);
          final len = bd.getUint16(x + 2, Endian.little);
          if (id == 0x0001) {
            var f = x + 4;
            if (size == 0xFFFFFFFF) {
              size = bd.getUint64(f, Endian.little);
              f += 8;
            }
            if (compressed == 0xFFFFFFFF) {
              compressed = bd.getUint64(f, Endian.little);
              f += 8;
            }
            if (offset == 0xFFFFFFFF) offset = bd.getUint64(f, Endian.little);
          }
          x += 4 + len;
        }
        entries.add(
          ZipEntry(
            name: name,
            method: bd.getUint16(at + 10, Endian.little),
            compressedSize: compressed,
            size: size,
            localOffset: offset,
            madeBy: bd.getUint16(at + 4, Endian.little),
            externalAttributes: bd.getUint32(at + 38, Endian.little),
          ),
        );
        at = extraEnd + commentLen;
      }
      return ZipReader._(path, entries);
    } on RangeError {
      throw ZipException('${p.basename(path)} — не zip-архив');
    } finally {
      await raf.close();
    }
  }

  /// (смещение оглавления, его размер, число записей) — из EOCD или его zip64-версии.
  static Future<(int, int, int)> _centralDirectory(RandomAccessFile raf) async {
    final length = await raf.length();
    final tail = length < 65557 ? length : 65557;
    await raf.setPosition(length - tail);
    final buf = await raf.read(tail);
    final bd = ByteData.sublistView(buf);
    var eocd = -1;
    for (var i = buf.length - 22; i >= 0; i--) {
      if (bd.getUint32(i, Endian.little) == 0x06054b50) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw ZipException('не zip-архив');
    var count = bd.getUint16(eocd + 10, Endian.little);
    var size = bd.getUint32(eocd + 12, Endian.little);
    var offset = bd.getUint32(eocd + 16, Endian.little);
    if (count == 0xFFFF || size == 0xFFFFFFFF || offset == 0xFFFFFFFF) {
      final loc = eocd - 20;
      if (loc >= 0 && bd.getUint32(loc, Endian.little) == 0x07064b50) {
        await raf.setPosition(bd.getUint64(loc + 8, Endian.little));
        final z = ByteData.sublistView(await raf.read(56));
        if (z.getUint32(0, Endian.little) != 0x06064b50) throw ZipException('повреждён zip64');
        count = z.getUint64(32, Endian.little);
        size = z.getUint64(40, Endian.little);
        offset = z.getUint64(48, Endian.little);
      }
    }
    return (offset, size, count);
  }

  Future<int> _dataOffset(RandomAccessFile raf, ZipEntry e) async {
    await raf.setPosition(e.localOffset);
    final h = ByteData.sublistView(await raf.read(30));
    if (h.lengthInBytes < 30 || h.getUint32(0, Endian.little) != 0x04034b50) {
      throw ZipException('повреждена запись ${e.name}');
    }
    return e.localOffset + 30 + h.getUint16(26, Endian.little) + h.getUint16(28, Endian.little);
  }

  /// Разжатые данные записи кусками. Каждый вызов открывает файл заново — чтения не мешают друг другу.
  Stream<List<int>> openRead(ZipEntry e, {int chunk = 1 << 20}) async* {
    if (e.method != 0 && e.method != 8) throw ZipException('${e.name}: неподдерживаемое сжатие (${e.method})');
    final raf = await File(path).open();
    try {
      var pos = await _dataOffset(raf, e);
      var left = e.compressedSize;
      final inflater = e.method == 8 ? RawZLibFilter.inflateFilter(raw: true) : null;
      await raf.setPosition(pos);
      while (left > 0) {
        final data = await raf.read(left < chunk ? left : chunk);
        if (data.isEmpty) throw ZipException('${e.name}: архив обрезан');
        left -= data.length;
        pos += data.length;
        if (inflater == null) {
          yield data;
          continue;
        }
        inflater.process(data, 0, data.length);
        List<int>? out;
        while ((out = inflater.processed(flush: false)) != null) {
          if (out!.isNotEmpty) yield out;
        }
      }
      if (inflater != null) {
        List<int>? out;
        while ((out = inflater.processed(end: true)) != null) {
          if (out!.isNotEmpty) yield out;
        }
      }
    } finally {
      await raf.close();
    }
  }

  Future<Uint8List> read(String name) async {
    final e = _byName[name];
    if (e == null) throw ZipException('В архиве нет $name');
    final b = BytesBuilder(copy: false);
    await for (final c in openRead(e)) {
      b.add(c);
    }
    return b.takeBytes();
  }

  /// Читает начало записи, пока `enough` не скажет «хватит» — для заголовков больших бинарников.
  Future<Uint8List> readPrefix(String name, bool Function(Uint8List soFar) enough) async {
    final e = _byName[name];
    if (e == null) throw ZipException('В архиве нет $name');
    final b = BytesBuilder(copy: false);
    await for (final c in openRead(e, chunk: 256 * 1024)) {
      b.add(c);
      if (enough(b.toBytes())) break;
    }
    return b.takeBytes();
  }

  /// Распаковка всего архива. Символьные ссылки в IPA почти не встречаются, а Windows
  /// без прав администратора их не создаёт — такие записи пропускаем и возвращаем список.
  Future<List<String>> extractAll(String dir) async {
    final skipped = <String>[];
    final root = p.normalize(p.absolute(dir));
    for (final e in entries) {
      final target = p.normalize(p.join(root, e.name));
      if (!p.isWithin(root, target)) throw ZipException('Подозрительный путь в архиве: ${e.name}');
      if (e.isDirectory) {
        await Directory(target).create(recursive: true);
        continue;
      }
      if (e.isSymlink) {
        skipped.add(e.name);
        continue;
      }
      await Directory(p.dirname(target)).create(recursive: true);
      final sink = File(target).openWrite();
      try {
        await sink.addStream(openRead(e));
      } finally {
        await sink.close();
      }
    }
    return skipped;
  }
}

/// Упаковка каталога в zip. Записи помечаются как созданные в Unix с правами 0755 для Mach-O
/// и 0644 для остального: без бита исполнения iOS может не запустить бинарник,
/// а пакет archive пишет «MS-DOS» и права Unix при распаковке игнорируются.
class ZipWriter {
  static Future<void> zipDirectory(String root, String sub, String output) async {
    final base = Directory(p.join(root, sub));
    final files = await base.list(recursive: true, followLinks: false).where((e) => e is File).cast<File>().toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    final encoder = ZipFileEncoder()..create(output);
    for (final f in files) {
      final name = p.relative(f.path, from: root).replaceAll(r'\', '/');
      final stream = InputFileStream(f.path);
      final entry = ArchiveFile.stream(name, stream)
        ..mode = await _isMachO(f) ? 0x81ED : 0x81A4
        ..lastModTime = (await f.lastModified()).millisecondsSinceEpoch ~/ 1000;
      encoder.addArchiveFile(entry);
      await stream.close();
    }
    await encoder.close();
    await markUnix(output);
  }

  static Future<bool> _isMachO(File f) async {
    final raf = await f.open();
    try {
      return MachO.isMachOMagic(await raf.read(4));
    } finally {
      await raf.close();
    }
  }

  /// Старший байт «version made by» = 3 (Unix): только тогда распаковщики учитывают права.
  static Future<void> markUnix(String path) async {
    final raf = await File(path).open(mode: FileMode.append);
    try {
      final (offset, size, _) = await ZipReader._centralDirectory(raf);
      await raf.setPosition(offset);
      final cd = await raf.read(size);
      final bd = ByteData.sublistView(cd);
      var at = 0;
      while (at + 46 <= cd.length && bd.getUint32(at, Endian.little) == 0x02014b50) {
        cd[at + 5] = 3;
        at += 46 + bd.getUint16(at + 28, Endian.little) + bd.getUint16(at + 30, Endian.little) + bd.getUint16(at + 32, Endian.little);
      }
      await raf.setPosition(offset);
      await raf.writeFrom(cd);
    } finally {
      await raf.close();
    }
  }
}
