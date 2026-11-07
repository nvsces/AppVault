import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:appvault/core/plist.dart';
import 'package:appvault/core/provisioning.dart';
import 'package:appvault/core/resigner.dart';
import 'package:appvault/core/subprocess.dart';
import 'package:appvault/core/tools.dart';
import 'package:appvault/core/zip.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures.dart';

/// Конвейер переподписи без настоящего rcodesign: вместо него программа, которая записывает
/// аргументы и файлы прав. Проверяется всё, что AppVault делает до и после подписи.
void main() {
  late Directory dir;
  late Directory compiledDir;
  late String compiledTool;
  late String fakeDir;
  final cert = Uint8List.fromList(utf8.encode('cert-der'));

  setUpAll(() async {
    compiledDir = await Fixtures.tempDir('native-test-tool');
    compiledTool = p.join(compiledDir.path, Platform.isWindows ? 'rcodesign.exe' : 'rcodesign');
    final result = await Process.run('dart', [
      'compile',
      'exe',
      'test/support/fake_rcodesign.dart',
      '-o',
      compiledTool,
    ], runInShell: Platform.isWindows);
    if (result.exitCode != 0) {
      throw StateError('Cannot compile test helper: ${result.stdout}\n${result.stderr}');
    }
  });

  tearDownAll(() async {
    await compiledDir.delete(recursive: true);
  });

  setUp(() async {
    dir = await Fixtures.tempDir('resign');
    fakeDir = p.join(dir.path, 'bin');
    await Directory(fakeDir).create();
    await File(compiledTool).copy(p.join(fakeDir, p.basename(compiledTool)));
    Toolbox.customDir = fakeDir;
  });

  tearDown(() async {
    Toolbox.customDir = null;
    await dir.delete(recursive: true);
  });

  ProvisioningProfile profile() => ProvisioningProfile.decode(
    Fixtures.mobileprovision(
      appID: '*',
      certificates: [cert],
      entitlements: {
        'keychain-access-groups': ['TEAMID1234.*'],
        'aps-environment': 'development',
      },
    ),
  );

  Future<ResignResult> resign(String ipa, ResignOptions options, List<String> log) => Resigner(log: log.add).resign(
    ipa: ipa,
    output: p.join(dir.path, 'out', 'signed.ipa'),
    credentials: (p12: '/certs/dev.p12', password: 'secret'),
    teamID: 'TEAMID1234',
    provider: ManualProfileProvider([profile()], sha1Hex(cert), 'TEAMID1234', ['UDID-1']),
    options: options,
  );

  test('профили и права в каждом бандле, мусор убран, права Unix сохранены', () async {
    final ipa = await Fixtures.ipa(
      dir,
      withWatch: true,
      entitlements: {
        'application-identifier': 'OLDTEAM123.com.example.demo',
        'keychain-access-groups': ['OLDTEAM123.com.example.demo'],
        'aps-environment': 'production',
        'com.apple.developer.icloud-services': ['CloudKit'],
      },
    );
    final log = <String>[];
    final result = await resign(ipa, ResignOptions(), log);
    expect(result.bundleID, 'com.example.demo');
    expect(result.droppedEntitlements['Demo.app'], ['com.apple.developer.icloud-services']);

    final args = File(p.join(fakeDir, 'args.txt')).readAsLinesSync();
    final sep = Platform.pathSeparator;
    expect(args, [
      'sign',
      '--p12-file',
      '/certs/dev.p12',
      '--p12-password-file',
      args[4],
      '--entitlements-xml-file',
      'PlugIns${sep}Share.appex:entitlements-0.plist',
      '--entitlements-xml-file',
      '@main:entitlements-1.plist',
      'Payload${sep}Demo.app',
    ]);
    expect(File(args[4]).existsSync(), isFalse, reason: 'файл с паролем удаляется сразу после подписи');

    final main = Plist.parseDict(File(p.join(fakeDir, 'entitlements-1.plist')).readAsBytesSync());
    expect(main['application-identifier'], 'TEAMID1234.com.example.demo');
    expect(main['aps-environment'], 'development');
    expect(main['keychain-access-groups'], ['TEAMID1234.com.example.demo']);
    final ext = Plist.parseDict(File(p.join(fakeDir, 'entitlements-0.plist')).readAsBytesSync());
    expect(ext['application-identifier'], 'TEAMID1234.com.example.demo.share');

    final zip = await ZipReader.open(result.output);
    final names = zip.names.toSet();
    expect(names, contains('Payload/Demo.app/embedded.mobileprovision'));
    expect(names, contains('Payload/Demo.app/PlugIns/Share.appex/embedded.mobileprovision'));
    expect(names.any((n) => n.contains('/Watch/')), isFalse);
    expect(names.contains('iTunesMetadata.plist'), isFalse);
    expect(zip['Payload/Demo.app/Demo']!.unixMode, 0x81ED);
    expect(zip['Payload/Demo.app/Info.plist']!.unixMode, 0x81A4);
    expect(log, contains('Удаляю приложение для часов (Watch)'));
  });

  test('суффикс команды переносится и на расширения', () async {
    final ipa = await Fixtures.ipa(dir);
    final result = await resign(ipa, ResignOptions(bundleIDMode: BundleIDMode.suffix), []);
    expect(result.bundleID, 'com.example.demo.TEAMID1234');
    final zip = await ZipReader.open(result.output);
    expect(Plist.parseDict(await zip.read('Payload/Demo.app/Info.plist'))['CFBundleIdentifier'], 'com.example.demo.TEAMID1234');
    expect(
      Plist.parseDict(await zip.read('Payload/Demo.app/PlugIns/Share.appex/Info.plist'))['CFBundleIdentifier'],
      'com.example.demo.TEAMID1234.share',
    );
  });

  test('зашифрованную сборку App Store переподписать нельзя', () async {
    final ipa = await Fixtures.ipa(dir, cryptid: 1);
    await expectLater(resign(ipa, ResignOptions(), []), throwsA(isA<ResignException>()));
  });

  test('вывод утилиты сохраняет кириллицу на границах блоков', () async {
    final lines = <String>[];
    final result = await Subprocess.check(compiledTool, ['--emit-split-utf8'], onStdout: lines.add);
    expect(lines, ['Передача приложения', 'Готово']);
    expect(result.out, 'Передача приложения\rГотово\n');
  });
}
