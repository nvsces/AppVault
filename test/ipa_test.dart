import 'dart:convert';
import 'dart:io';

import 'package:appvault/core/ipa.dart';
import 'package:appvault/core/library.dart';
import 'package:appvault/core/png.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures.dart';

void main() {
  test('разбор IPA: сведения, расширения, метаданные, иконка', () async {
    final dir = await Fixtures.tempDir('ipa');
    final ipa = await Fixtures.ipa(dir, cryptid: 1, withWatch: true);
    final r = await IPAInspector.inspect(ipa);
    final info = r.info;
    expect(info.bundleID, 'com.example.demo');
    expect(info.name, 'Демо');
    expect(info.version, '1.2.3');
    expect(info.build, '45');
    expect(info.minimumOS, '15.0');
    expect(info.appPath, 'Payload/Demo.app');
    expect(info.encryption, EncryptionState.encrypted);
    expect(info.kind, IPAKind.appStore);
    expect(info.architectures, ['arm64']);
    expect(info.extensions, ['PlugIns/Share.appex']);
    expect(info.hasWatchApp, isTrue);
    expect(info.store?.itemID, 123456789);
    expect(info.store?.purchaserAppleID, 'me@example.com');
    expect(info.store?.externalVersionID, 987);
    expect(info.store?.purchaseDate, DateTime.utc(2024, 1, 2, 3, 4, 5));
    // Из двух иконок выбрана @3x (3×3), перекодированная из CgBI.
    expect(PngDecoder.isPng(r.icon!) && !PngDecoder.isCgBI(r.icon!), isTrue);
    expect(r.icon!.sublist(16, 24), [0, 0, 0, 3, 0, 0, 0, 3]);
    // JSON туда и обратно — так сведения хранятся в index.json.
    final again = IPAInfo.fromJson(jsonDecode(jsonEncode(info.toJson())) as Map<String, dynamic>);
    expect(jsonEncode(again.toJson()), jsonEncode(info.toJson()));
    await dir.delete(recursive: true);
  });

  test('бинарный Info.plist и незашифрованный бинарник', () async {
    final dir = await Fixtures.tempDir('ipa2');
    final r = await IPAInspector.inspect(await Fixtures.ipa(dir, binaryPlist: true, withExtension: false, withStoreMetadata: false));
    expect(r.info.bundleID, 'ru.example.app');
    expect(r.info.version, '2.5');
    expect(r.info.kind, IPAKind.resignable);
    expect(r.info.store, isNull);
    await dir.delete(recursive: true);
  });

  test('не IPA', () async {
    final dir = await Fixtures.tempDir('notipa');
    await Fixtures.write(p.join(dir.path, 'src', 'readme.txt'), utf8.encode('hi'));
    await Fixtures.zip(p.join(dir.path, 'src'), p.join(dir.path, 'x.ipa'));
    await expectLater(IPAInspector.inspect(p.join(dir.path, 'x.ipa')), throwsA(isA<IPAException>()));
    await dir.delete(recursive: true);
  });

  test('библиотека: добавление, индекс, удаление', () async {
    final dir = await Fixtures.tempDir('lib');
    final ipa = await Fixtures.ipa(dir);
    final storage = LibraryStorage(p.join(dir.path, 'Library'));
    final item = await storage.add(ipa, const AppStoreSource(123456789, '987'));
    expect(File(ipa).existsSync(), isTrue);
    expect(File(storage.ipaPath(item)).existsSync(), isTrue);
    expect(File(storage.iconPath(item)).existsSync(), isTrue);
    storage.save([item]);
    final loaded = storage.load();
    expect(loaded.single.id, item.id);
    expect((loaded.single.source as AppStoreSource).versionID, '987');
    await storage.remove(item);
    expect(storage.load(), isEmpty);
    await dir.delete(recursive: true);
  });

  test('имя файла без запрещённых в Windows символов', () {
    IPAInfo info(String name) => IPAInfo(
      bundleID: 'a.b',
      name: name,
      version: '1.0',
      build: '1',
      executable: 'x',
      appPath: 'Payload/x.app',
      encryption: EncryptionState.unknown,
      architectures: const [],
      hasSinf: false,
      extensions: const [],
      hasWatchApp: false,
      fileSize: 0,
    );
    expect(LibraryStorage.fileNameFor(info('Банк: <Онлайн>?')), 'Банк- -Онлайн-- 1.0.ipa');
    expect(LibraryStorage.fileNameFor(info('a/b\\c|d')), 'a-b-c-d 1.0.ipa');
  });

  // Сверка с Mac-версией на настоящих IPA из её библиотеки, если она есть на этой машине.
  final macIndex = File(p.join(Platform.environment['HOME'] ?? '', 'Library/Application Support/AppVault/Library/index.json'));
  test(
    'совпадает с Mac-версией на реальных IPA',
    () async {
      final items = (jsonDecode(macIndex.readAsStringSync()) as List).cast<Map<String, dynamic>>();
      final available = items.where(
        (item) => File(p.join(macIndex.parent.path, item['id'] as String, item['fileName'] as String)).existsSync(),
      );
      if (available.isEmpty) {
        markTestSkipped('в индексе Mac-версии нет доступных IPA');
        return;
      }
      var checked = 0;
      for (final item in available) {
        final path = p.join(macIndex.parent.path, item['id'] as String, item['fileName'] as String);
        if (!File(path).existsSync()) continue;
        final mac = item['info'] as Map<String, dynamic>;
        final info = (await IPAInspector.inspect(path)).info;
        final label = mac['bundleID'];
        expect(info.bundleID, mac['bundleID'], reason: label);
        expect(info.name, mac['name'], reason: label);
        expect(info.version, mac['version'], reason: label);
        expect(info.executable, mac['executable'], reason: label);
        expect(info.encryption.name, mac['encryption'], reason: label);
        expect(info.architectures, mac['architectures'], reason: label);
        expect(info.hasSinf, mac['hasSinf'], reason: label);
        expect(info.extensions.toSet(), (mac['extensions'] as List).toSet(), reason: label);
        expect(info.hasWatchApp, mac['hasWatchApp'], reason: label);
        expect(info.store?.itemID, (mac['store'] as Map?)?['itemID'], reason: label);
        expect(info.store?.externalVersionID, (mac['store'] as Map?)?['externalVersionID'], reason: label);
        checked++;
      }
      expect(checked, greaterThan(0));
      // ignore: avoid_print
      print('Сверено с Mac-версией: $checked IPA');
    },
    skip: macIndex.existsSync() ? false : 'нет библиотеки Mac-версии',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
