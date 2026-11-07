// Проверка окружения без интерфейса: какие утилиты найдены, видны ли устройства, есть ли вход в App Store.
// Только чтение — ничего не устанавливает и не скачивает.
//
//   dart run tool/smoke.dart [путь к .ipa]
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:appvault/core/devices.dart';
import 'package:appvault/core/ipa.dart';
import 'package:appvault/core/ipatool.dart';
import 'package:appvault/core/paths.dart';
import 'package:appvault/core/secrets.dart';
import 'package:appvault/core/tools.dart';

Future<void> main(List<String> args) async {
  final paths = AppPaths.standard();
  Toolbox.dataDir = paths.tools;
  IPATool.keychainPassphrase = SecretStore(paths.secrets).get('ipatool-keychain');

  print('Утилиты:');
  for (final t in Tool.values) {
    print('  ${t.fileName.padRight(22)} ${Toolbox.path(t) ?? '— не найден'}');
  }

  final seen = await DeviceClient.scan();
  print('\nУстройства: ${seen.length}');
  for (final MapEntry(key: udid, value: conns) in seen.entries) {
    final d = await DeviceClient.describe(udid, conns);
    print('  ${d.name} · ${d.modelName} · iOS ${d.productVersion} · ${d.connectionTitle} · режим разработчика: ${d.developerMode}');
    try {
      final apps = await DeviceClient.installedApps(udid, d.useNetwork);
      print('    приложений: ${apps.length}');
      final store = apps.where((a) => a.isAppStore).firstOrNull;
      if (store != null) {
        final meta = await DeviceClient.storeMetadata(store.bundleID, udid, d.useNetwork);
        print(
          '    ${store.name} ${store.version}: ID ${meta?.metadata.itemID}, версия ${meta?.metadata.externalVersionID}, '
          'TestFlight: ${meta?.testFlight}',
        );
      }
    } catch (e) {
      print('    ошибка: $e');
    }
  }

  if (Toolbox.path(Tool.ipatool) != null) {
    final account = await IPATool.account();
    print('\nApp Store: ${account == null ? 'вход не выполнен' : '${account.name} <${account.email}>'}');
  }

  for (final path in args) {
    final r = await IPAInspector.inspect(path);
    final i = r.info;
    print(
      '\n$path\n  ${i.name} ${i.version} (${i.bundleID}) · ${i.encryption.name} · ${i.architectures.join(', ')} · '
      'расширения: ${i.extensions.length} · иконка: ${r.icon?.length ?? 0} байт',
    );
  }
  exit(0);
}
