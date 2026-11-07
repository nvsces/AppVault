import 'dart:io';

import 'package:appvault/core/secrets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures.dart';

void main() {
  test('секрет сохраняется, читается и удаляется', () async {
    final dir = await Fixtures.tempDir('secrets');
    final store = SecretStore(p.join(dir.path, 'Secrets'));
    expect(store.get('k'), isNull);
    store.set('k', 'пароль: p@ss «12»');
    expect(store.get('k'), 'пароль: p@ss «12»');
    // На Windows файл зашифрован DPAPI — открытого текста в нём нет.
    final file = Directory(store.directory).listSync().whereType<File>().single;
    if (Platform.isWindows) {
      expect(file.path.endsWith('.dpapi'), isTrue);
      expect(String.fromCharCodes(file.readAsBytesSync()).contains('p@ss'), isFalse);
    }
    store.delete('k');
    expect(store.get('k'), isNull);
    await dir.delete(recursive: true);
  });
}
