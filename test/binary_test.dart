import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:appvault/core/macho.dart';
import 'package:appvault/core/plist.dart';
import 'package:appvault/core/png.dart';
import 'package:appvault/core/zip.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures.dart';

void main() {
  group('plist', () {
    test('бинарный plist со всеми типами', () {
      final d = Plist.parseDict(File('test/fixtures/sample.bplist').readAsBytesSync());
      expect(d['CFBundleIdentifier'], 'ru.example.app');
      expect(d['Count'], 42);
      expect(d['Big'], 1 << 40);
      expect(d['Neg'], -5);
      expect(d['Pi'], 3.25);
      expect(d['Flag'], true);
      expect(d['Off'], false);
      expect(d['Data'], Uint8List.fromList([0, 1, 255, 104, 105]));
      expect(d['Date'], DateTime.utc(2024, 5, 6, 7, 8, 9));
      expect(d['Unicode'], 'Привет, мир');
      expect(d['List'], [
        'a',
        1,
        {'k': 'v'},
      ]);
      expect(d['Empty'], <String, dynamic>{});
    });

    test('XML туда и обратно', () {
      final value = {
        'a': 'x < y & z',
        'n': 7,
        'r': 1.5,
        't': true,
        'list': ['q', 2, false],
        'data': Uint8List.fromList([1, 2, 3]),
        'date': DateTime.utc(2025, 1, 2, 3, 4, 5),
        'nested': {'k': <String>[]},
      };
      expect(Plist.parse(utf8.encode(Plist.toXml(value))), value);
    });
  });

  group('Mach-O', () {
    test('шифрование тонкого бинарника', () {
      expect((MachO.probe(Fixtures.machO(cryptid: 1)) as MachOSlices).isEncrypted, isTrue);
      final dec = MachO.probe(Fixtures.machO(cryptid: 0)) as MachOSlices;
      expect(dec.isEncrypted, isFalse);
      expect(dec.slices.single, const MachOSlice('arm64', false));
      expect((MachO.probe(Fixtures.machO()) as MachOSlices).slices.single.encrypted, isNull);
    });

    test('толстый бинарник: зашифрован, если зашифрован любой срез', () {
      final r = MachO.probe(Fixtures.fat([Fixtures.machO(cryptid: 0), Fixtures.machO(cryptid: 1, cpu: 12)])) as MachOSlices;
      expect(r.slices.map((s) => s.cpu), ['arm64', 'armv7']);
      expect(r.isEncrypted, isTrue);
    });

    test('обрезанный толстый бинарник просит ещё данных', () {
      final fat = Fixtures.fat([Fixtures.machO(cryptid: 1)]);
      expect(MachO.probe(fat.sublist(0, 100)), isA<MachONeedMore>());
    });

    test('не Mach-O', () {
      expect(MachO.probe(Uint8List.fromList(utf8.encode('#!/bin/sh\necho hi\n'))), isA<MachONotMachO>());
      expect(MachO.probe(Uint8List.fromList([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 50])), isA<MachONotMachO>());
    });

    test('права из подписи бинарника', () async {
      final dir = await Fixtures.tempDir('macho');
      final f = p.join(dir.path, 'bin');
      await File(f).writeAsBytes(Fixtures.machO(entitlements: {'application-identifier': 'T.a.b', 'get-task-allow': true}));
      expect(await MachO.entitlements(f), {'application-identifier': 'T.a.b', 'get-task-allow': true});
      await File(f).writeAsBytes(Fixtures.machO(cryptid: 0));
      expect(await MachO.entitlements(f), isEmpty);
      await dir.delete(recursive: true);
    });
  });

  group('PNG', () {
    List<int> pixelsOf(Uint8List png) {
      final r = PngDecoder.isPng(png) ? png : throw StateError('not png');
      final b = ByteData.sublistView(r);
      final width = b.getUint32(16);
      final idatLength = b.getUint32(33);
      final raw = ZLibDecoder().convert(r.sublist(41, 41 + idatLength));
      final out = <int>[];
      for (var y = 0; y < raw.length ~/ (width * 4 + 1); y++) {
        out.addAll(raw.sublist(y * (width * 4 + 1) + 1, (y + 1) * (width * 4 + 1)));
      }
      return out;
    }

    test('CgBI с фильтрами → обычный PNG', () {
      final pixels = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 10, 20, 30, 255];
      final png = PngDecoder.normalize(Fixtures.cgbiPNG(2, 2, pixels))!;
      expect(PngDecoder.isCgBI(png), isFalse);
      expect(pixelsOf(png), pixels);
    });

    test('полупрозрачный пиксель сохраняет альфу', () {
      final png = PngDecoder.normalize(Fixtures.cgbiPNG(1, 1, [200, 100, 50, 128]))!;
      final px = pixelsOf(png);
      expect(px[3], 128);
      expect((px[0] - 200).abs() <= 2 && (px[1] - 100).abs() <= 2 && (px[2] - 50).abs() <= 2, isTrue);
    });

    test('обычный PNG — как есть, не PNG — null', () {
      final png = PngDecoder.encodeRGBA(1, 1, Uint8List.fromList([1, 2, 3, 4]));
      expect(PngDecoder.normalize(png), same(png));
      expect(PngDecoder.normalize(Uint8List.fromList([1, 2, 3])), isNull);
      expect(PngDecoder.crc32(ascii.encode('IEND')), 0xAE426082);
    });
  });

  group('zip', () {
    test('упаковка с правами Unix и чтение', () async {
      final dir = await Fixtures.tempDir('zip');
      final app = p.join(dir.path, 'Payload', 'A.app');
      await Fixtures.write(p.join(app, 'A'), Fixtures.machO(cryptid: 0));
      await Fixtures.write(p.join(app, 'Info.plist'), utf8.encode('plist'));
      final big = Uint8List.fromList(List.generate(3 << 20, (i) => (i * 31) & 0xFF));
      await Fixtures.write(p.join(app, 'big.bin'), big);
      final out = p.join(dir.path, 'out.ipa');
      await ZipWriter.zipDirectory(dir.path, 'Payload', out);

      final zip = await ZipReader.open(out);
      expect(zip.names.toList()..sort(), ['Payload/A.app/A', 'Payload/A.app/Info.plist', 'Payload/A.app/big.bin']);
      expect(zip['Payload/A.app/A']!.madeBy >> 8, 3);
      expect(zip['Payload/A.app/A']!.unixMode, 0x81ED);
      expect(zip['Payload/A.app/Info.plist']!.unixMode, 0x81A4);
      expect(await zip.read('Payload/A.app/big.bin'), big);
      final prefix = await zip.readPrefix('Payload/A.app/big.bin', (d) => d.length >= 1000);
      expect(prefix.length, lessThan(big.length));
      expect(prefix.sublist(0, 1000), big.sublist(0, 1000));

      final unpacked = p.join(dir.path, 'unpacked');
      expect(await zip.extractAll(unpacked), isEmpty);
      expect(File(p.join(unpacked, 'Payload', 'A.app', 'big.bin')).readAsBytesSync(), big);
      await dir.delete(recursive: true);
    });

    test('не zip', () async {
      final dir = await Fixtures.tempDir('nozip');
      final f = p.join(dir.path, 'x.ipa');
      await File(f).writeAsString('not a zip at all');
      await expectLater(ZipReader.open(f), throwsA(isA<ZipException>()));
      await dir.delete(recursive: true);
    });
  });
}
