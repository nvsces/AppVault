import 'dart:io';

import 'package:appvault/core/devices.dart';
import 'package:appvault/core/library.dart';
import 'package:appvault/core/paths.dart';
import 'package:appvault/state/vault_store.dart';
import 'package:appvault/ui/app.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'fixtures.dart';

void main() {
  late Directory dir;
  late VaultStore store;

  setUp(() async {
    dir = await Fixtures.tempDir('ui');
    store = VaultStore(paths: AppPaths(p.join(dir.path, 'data')), startPolling: false);
  });

  tearDown(() async {
    store.dispose();
    await dir.delete(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester, {Size size = const Size(1360, 860)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(AppVaultApp(store: store));
    await tester.pump();
  }

  Future<void> open(WidgetTester tester, String section) async {
    await tester.tap(find.widgetWithText(ListTile, section).first);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  testWidgets('все разделы открываются без ошибок', (tester) async {
    await tester.runAsync(() async {
      final ipa = await Fixtures.ipa(dir, cryptid: 1);
      store.addItem(await store.storage.add(ipa, const AppStoreSource(123456789, '987')));
      final ipa2 = await Fixtures.ipa(await Directory(p.join(dir.path, 'b')).create(), cryptid: 0, bundleID: 'org.open.source');
      store.addItem(await store.storage.add(ipa2, ImportedSource(ipa2)));
    });
    store.devices = [
      const Device(
        udid: '00008110-000471041439401E',
        name: 'iPhone (тест)',
        productType: 'iPhone14,2',
        productVersion: '18.0',
        buildVersion: '22A',
        connections: {Connection.network},
        developerMode: false,
      ),
    ];
    store.installedApps['00008110-000471041439401E'] = const [
      InstalledApp(bundleID: 'ru.winelab', name: 'Винлаб', version: '5.32.0', signer: 'Apple iPhone OS Application Signing'),
      InstalledApp(bundleID: 'com.my.dev', name: 'Своя сборка', version: '1.0', signer: 'Apple Development: X'),
    ];

    await pumpApp(tester);
    expect(find.text('Демо'), findsWidgets);
    expect(find.text('Установка'), findsOneWidget);
    // Выбираем сборку App Store (последняя добавленная — сверху, это незашифрованная).
    await tester.tap(find.text('com.example.demo'));
    await tester.pumpAndSettle();

    // Диалог установки сборки App Store предупреждает про Apple ID покупателя.
    await tester.tap(find.textContaining('На iPhone (тест)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('me@example.com'), findsWidgets);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();

    for (final section in ['App Store', 'Устройства', 'Подпись', 'Задачи', 'Настройки', 'Библиотека']) {
      await open(tester, section);
      expect(tester.takeException(), isNull, reason: section);
    }

    await open(tester, 'Устройства');
    expect(find.text('Винлаб'), findsOneWidget);
    expect(find.text('выключен'), findsOneWidget);

    // Правый клик по приложению из App Store — пункт «Скачать в библиотеку» (без входа — неактивный).
    await tester.tap(find.text('Винлаб'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('Скачать в библиотеку'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // У своей сборки такого пункта нет.
    await tester.tap(find.text('Своя сборка'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('Скачать в библиотеку'), findsNothing);
    expect(find.text('Удалить с устройства'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
  });

  testWidgets('узкое окно не ломает разметку', (tester) async {
    await tester.runAsync(() async {
      final ipa = await Fixtures.ipa(dir);
      store.addItem(await store.storage.add(ipa, ImportedSource(ipa)));
    });
    await pumpApp(tester, size: const Size(1000, 700));
    for (final section in ['Устройства', 'Подпись', 'Настройки', 'Задачи', 'App Store', 'Библиотека']) {
      await open(tester, section);
      expect(tester.takeException(), isNull, reason: section);
    }
  });

  testWidgets('задача с ошибкой видна в журнале', (tester) async {
    await pumpApp(tester);
    store.run('Проверка', (job) async {
      job.append('шаг 1');
      throw Exception('что-то пошло не так');
    });
    await tester.pump();
    await open(tester, 'Задачи');
    expect(find.text('Проверка'), findsOneWidget);
    expect(find.textContaining('что-то пошло не так'), findsOneWidget);
  });
}
