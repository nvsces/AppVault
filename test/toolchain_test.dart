import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:appvault/core/identity.dart';
import 'package:appvault/core/macho.dart';
import 'package:appvault/core/resigner.dart';
import 'package:appvault/core/secrets.dart';
import 'package:appvault/core/subprocess.dart';
import 'package:appvault/core/tools.dart';
import 'package:appvault/core/zip.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures.dart';

// Uses the real pinned binaries, without an Apple ID, developer account or iPhone.
// APPVAULT_TEST_TOOLS=<folder> flutter test test/toolchain_test.dart
void main() {
  final tools = Platform.environment['APPVAULT_TEST_TOOLS'];
  group('настоящий комплект утилит', skip: tools == null ? 'не задан APPVAULT_TEST_TOOLS' : false, () {
    late Directory dir;
    late String? previousTools;

    setUp(() async {
      dir = await Directory(p.join((await Fixtures.tempDir('toolchain')).path, 'Папка с пробелами')).create();
      previousTools = Toolbox.customDir;
      Toolbox.customDir = tools;
    });

    tearDown(() async {
      Toolbox.customDir = previousTools;
      await dir.parent.delete(recursive: true);
    });

    test('импорт .p12 и сохранение пароля', () async {
      final p12 = p.join(dir.path, 'сертификат.p12');
      const password = 'пароль p@ss «12»';
      await Subprocess.check(Toolbox.require(Tool.rcodesign), [
        'generate-self-signed-certificate',
        '--person-name',
        'AppVault Test',
        '--team-id',
        'TEAMID1234',
        '--p12-file',
        p12,
        '--p12-password',
        password,
      ]);
      final library = IdentityLibrary(p.join(dir.path, 'Identities'), SecretStore(p.join(dir.path, 'Secrets')));
      final identity = await library.import(p12, password);
      expect(identity.name, contains('AppVault Test'));
      expect(identity.teamID, 'TEAMID1234');
      expect(identity.isDevelopment && identity.isValid, isTrue);
      expect(library.password(identity), password);
      expect(library.load().single.sha1, identity.sha1);
      await expectLater(IdentityLibrary.analyze(p12, 'wrong password'), throwsA(isA<IdentityException>()));
      library.remove(identity);
      expect(library.load(), isEmpty);
    });

    test('переподпись IPA с расширением через настоящий rcodesign', () async {
      final ipa = await Fixtures.ipa(dir);
      for (final relative in ['Demo', p.join('PlugIns', 'Share.appex', 'Share')]) {
        await File(p.join(dir.path, 'src', 'Payload', 'Demo.app', relative)).writeAsBytes(_signableMachO());
      }
      await Fixtures.zip(p.join(dir.path, 'src'), ipa);
      final result = await Resigner().resign(
        ipa: ipa,
        output: p.join(dir.path, 'Подписано.ipa'),
        credentials: null,
        teamID: 'TEAMID1234',
        provider: null,
        options: ResignOptions(),
      );
      final zip = await ZipReader.open(result.output);
      for (final binary in ['Payload/Demo.app/Demo', 'Payload/Demo.app/PlugIns/Share.appex/Share']) {
        final data = await zip.read(binary);
        final slices = MachO.probe(data) as MachOSlices;
        expect(slices.slices.single.cpu, 'arm64');
        final bytes = ByteData.sublistView(data);
        var command = 32;
        var signatureSize = 0;
        for (var i = 0; i < bytes.getUint32(16, Endian.little); i++) {
          if (bytes.getUint32(command, Endian.little) == MachO.lcCodeSignature) {
            signatureSize = bytes.getUint32(command + 12, Endian.little);
            final offset = bytes.getUint32(command + 8, Endian.little);
            expect(bytes.getUint32(offset), 0xFADE0CC0);
          }
          command += bytes.getUint32(command + 4, Endian.little);
        }
        expect(signatureSize, greaterThan(8));
        expect(zip[binary]!.unixMode, 0x81ED);
      }
      expect(zip['Payload/Demo.app/_CodeSignature/CodeResources'], isNotNull);
      expect(zip['Payload/Demo.app/PlugIns/Share.appex/_CodeSignature/CodeResources'], isNotNull);
      expect(zip['iTunesMetadata.plist'], isNull);
    });
  });
}

// A minimal arm64 Mach-O with a text section and linkedit segment. It can be
// signed by rcodesign; it is test data and is never executed on a device.
Uint8List _signableMachO() {
  List<int> u32(List<int> values) => [for (final v in values) ...Fixtures.le32(v)];
  List<int> u64(int value) => (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List();
  List<int> name(String value) => [...ascii.encode(value), ...List.filled(16 - value.length, 0)];
  List<int> segment(String id, int address, int offset, int protection, [List<int> sections = const []]) => [
    ...u32([0x19, 72 + sections.length]),
    ...name(id),
    ...u64(address),
    ...u64(4096),
    ...u64(offset),
    ...u64(4096),
    ...u32([protection, protection, sections.length ~/ 80, 0]),
    ...sections,
  ];
  final section = [
    ...name('__text'),
    ...name('__TEXT'),
    ...u64(0x100000400),
    ...u64(4),
    ...u32([1024, 2, 0, 0, 0x80000400, 0, 0, 0]),
  ];
  final commands = [
    ...segment('__TEXT', 0x100000000, 0, 5, section),
    ...segment('__LINKEDIT', 0x100001000, 4096, 1),
    ...u32([2, 24, 4096, 0, 4096, 1]),
    ...u32([0x32, 24, 2, 0xF0000, 0xF0000, 0]),
  ];
  final header = u32([0xFEEDFACF, 0x0100000C, 0, 2, 4, commands.length, 0, 0]);
  return Uint8List(8192)
    ..setRange(0, header.length, header)
    ..setRange(header.length, header.length + commands.length, commands)
    ..setRange(1024, 1028, Fixtures.le32(0xD65F03C0));
}
