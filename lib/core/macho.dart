import 'dart:io';
import 'dart:typed_data';

import 'plist.dart';

class MachOSlice {
  const MachOSlice(this.cpu, this.encrypted);
  final String cpu;

  /// `null` — команды шифрования нет вовсе (своя сборка, симулятор).
  final bool? encrypted;

  @override
  bool operator ==(Object other) => other is MachOSlice && other.cpu == cpu && other.encrypted == encrypted;
  @override
  int get hashCode => Object.hash(cpu, encrypted);
}

sealed class MachOProbe {
  const MachOProbe();
}

class MachOSlices extends MachOProbe {
  const MachOSlices(this.slices);
  final List<MachOSlice> slices;
  bool get isEncrypted => slices.any((s) => s.encrypted == true);
}

/// Нужно прочитать не меньше указанного числа байт с начала файла.
class MachONeedMore extends MachOProbe {
  const MachONeedMore(this.bytes);
  final int bytes;
}

class MachONotMachO extends MachOProbe {
  const MachONotMachO();
}

/// Разбор заголовка Mach-O: архитектуры и флаг шифрования FairPlay (`cryptid` в LC_ENCRYPTION_INFO).
/// Зашифрованный бинарник из App Store запускается только с лицензией купившего Apple ID,
/// переподписать его нельзя — от этого флага зависит, какой путь установки доступен.
class MachO {
  static const lcEncryptionInfo = 0x21;
  static const lcEncryptionInfo64 = 0x2C;
  static const lcCodeSignature = 0x1D;

  static bool isMachOMagic(List<int> b) {
    if (b.length < 4) return false;
    final be = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    final le = (b[3] << 24) | (b[2] << 16) | (b[1] << 8) | b[0];
    return be == 0xCAFEBABE || be == 0xCAFEBABF || le == 0xFEEDFACF || le == 0xFEEDFACE;
  }

  static MachOProbe probe(Uint8List data) {
    final r = _Reader(data);
    final magic = r.u32(0, big: true);
    if (magic == null) return const MachONeedMore(4096);
    if (magic != 0xCAFEBABE && magic != 0xCAFEBABF) return _thin(r, 0);

    final is64 = magic == 0xCAFEBABF;
    final count = r.u32(4, big: true);
    if (count == null) return const MachONeedMore(4096);
    // 0xCAFEBABE — ещё и сигнатура Java class; у них на этом месте версия, а не число архитектур.
    if (count == 0 || count >= 32) return const MachONotMachO();
    final entrySize = is64 ? 32 : 20;
    final headerEnd = 8 + count * entrySize;
    if (data.length < headerEnd) return MachONeedMore(headerEnd);

    final slices = <MachOSlice>[];
    for (var i = 0; i < count; i++) {
      final base = 8 + i * entrySize;
      final offset = is64 ? r.u64(base + 8, big: true) ?? 0 : r.u32(base + 8, big: true) ?? 0;
      switch (_thin(r, offset)) {
        case MachOSlices(slices: final s):
          slices.addAll(s);
        case MachONeedMore(bytes: final n):
          return MachONeedMore(n);
        case MachONotMachO():
          return const MachONotMachO();
      }
    }
    return MachOSlices(slices);
  }

  static MachOProbe _thin(_Reader r, int off) {
    final magic = r.u32(off);
    if (magic == null) return MachONeedMore(off + 64 * 1024);
    final int headerSize;
    switch (magic) {
      case 0xFEEDFACF:
        headerSize = 32;
      case 0xFEEDFACE:
        headerSize = 28;
      default:
        return const MachONotMachO();
    }
    final cpu = r.u32(off + 4), subtype = r.u32(off + 8), ncmds = r.u32(off + 16), sizeofcmds = r.u32(off + 20);
    if (cpu == null || subtype == null || ncmds == null || sizeofcmds == null) {
      return MachONeedMore(off + headerSize + 64 * 1024);
    }
    final end = off + headerSize + sizeofcmds;
    if (r.length < end) return MachONeedMore(end);

    bool? encrypted;
    var p = off + headerSize;
    for (var i = 0; i < ncmds; i++) {
      final cmd = r.u32(p), size = r.u32(p + 4);
      if (cmd == null || size == null || size < 8) break;
      if (cmd == lcEncryptionInfo || cmd == lcEncryptionInfo64) encrypted = (r.u32(p + 16) ?? 0) != 0;
      p += size;
      if (p > end) break;
    }
    return MachOSlices([MachOSlice(cpuName(cpu, subtype), encrypted)]);
  }

  static String cpuName(int type, int subtype) {
    switch (type) {
      case 0x0100000C:
        return (subtype & 0xFF) == 2 ? 'arm64e' : 'arm64';
      case 12:
        return 'armv7';
      case 0x01000007:
        return 'x86_64';
      case 7:
        return 'i386';
      default:
        return 'cpu 0x${type.toRadixString(16).toUpperCase()}';
    }
  }

  /// Заголовок файла на диске: читаем столько, сколько попросит разбор.
  static Future<MachOProbe> probeFile(String path) async {
    final raf = await File(path).open();
    try {
      var want = 4096;
      while (true) {
        await raf.setPosition(0);
        final data = await raf.read(want);
        final result = probe(data);
        if (result is MachONeedMore && result.bytes > data.length && data.length == want) {
          want = result.bytes;
          continue;
        }
        return result is MachONeedMore ? const MachONotMachO() : result;
      }
    } finally {
      await raf.close();
    }
  }

  /// Права, с которыми бинарник подписан сейчас: блоб 0xfade7171 в подписи первого среза.
  /// Неподписанный бинарник — пустой словарь.
  static Future<Map<String, dynamic>> entitlements(String path) async {
    final raf = await File(path).open();
    try {
      final head = await raf.read(4096);
      final r = _Reader(head);
      var slice = 0;
      final magic = r.u32(0, big: true);
      if (magic == 0xCAFEBABE || magic == 0xCAFEBABF) {
        slice = magic == 0xCAFEBABF ? r.u64(16, big: true) ?? 0 : r.u32(16, big: true) ?? 0;
      }
      await raf.setPosition(slice);
      final header = _Reader(await raf.read(32));
      final thin = header.u32(0);
      if (thin != 0xFEEDFACF && thin != 0xFEEDFACE) return {};
      final headerSize = thin == 0xFEEDFACF ? 32 : 28;
      final ncmds = header.u32(16) ?? 0, sizeofcmds = header.u32(20) ?? 0;
      await raf.setPosition(slice + headerSize);
      final cmds = _Reader(await raf.read(sizeofcmds));
      var p = 0;
      int? sigOffset, sigSize;
      for (var i = 0; i < ncmds; i++) {
        final cmd = cmds.u32(p), size = cmds.u32(p + 4);
        if (cmd == null || size == null || size < 8) break;
        if (cmd == lcCodeSignature) {
          sigOffset = cmds.u32(p + 8);
          sigSize = cmds.u32(p + 12);
        }
        p += size;
      }
      if (sigOffset == null || sigSize == null || sigSize == 0) return {};
      await raf.setPosition(slice + sigOffset);
      final sig = _Reader(await raf.read(sigSize));
      if (sig.u32(0, big: true) != 0xFADE0CC0) return {};
      final count = sig.u32(8, big: true) ?? 0;
      for (var i = 0; i < count; i++) {
        final blob = sig.u32(12 + i * 8 + 4, big: true);
        if (blob == null || sig.u32(blob, big: true) != 0xFADE7171) continue;
        final length = sig.u32(blob + 4, big: true) ?? 0;
        if (blob + length > sig.length || length < 8) return {};
        return Plist.parseDict(sig.data.sublist(blob + 8, blob + length));
      }
      return {};
    } on FormatException {
      return {};
    } finally {
      await raf.close();
    }
  }
}

/// Чтение целых по смещению без выравнивания; `null`, если данных не хватает.
class _Reader {
  _Reader(this.data);
  final Uint8List data;
  int get length => data.length;

  int? u32(int o, {bool big = false}) {
    if (o < 0 || o + 4 > data.length) return null;
    final b0 = data[o], b1 = data[o + 1], b2 = data[o + 2], b3 = data[o + 3];
    return big ? (b0 << 24 | b1 << 16 | b2 << 8 | b3) : (b3 << 24 | b2 << 16 | b1 << 8 | b0);
  }

  int? u64(int o, {bool big = false}) {
    final a = u32(o, big: big), b = u32(o + 4, big: big);
    if (a == null || b == null) return null;
    return big ? (a << 32 | b) : (b << 32 | a);
  }
}
