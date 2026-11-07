import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Где AppVault хранит данные. На Windows — `%LOCALAPPDATA%\AppVault`: IPA весят гигабайты,
/// в перемещаемом профиле (Roaming) им не место. `APPVAULT_HOME` переопределяет корень (тесты).
class AppPaths {
  AppPaths(this.root);

  factory AppPaths.standard() {
    final env = Platform.environment;
    final override = env['APPVAULT_HOME'];
    if (override != null && override.isNotEmpty) return AppPaths(override);
    if (Platform.isWindows) {
      final local = env['LOCALAPPDATA'] ?? p.join(env['USERPROFILE'] ?? '.', 'AppData', 'Local');
      return AppPaths(p.join(local, 'AppVault'));
    }
    return AppPaths(p.join(home, '.appvault'));
  }

  final String root;

  String get library => p.join(root, 'Library');
  String get profiles => p.join(root, 'Profiles');
  String get identities => p.join(root, 'Identities');
  String get secrets => p.join(root, 'Secrets');
  String get tools => p.join(root, 'tools');
  String get settingsFile => p.join(root, 'settings.json');

  static String get home => Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';

  /// Временная папка под одну операцию.
  static Future<Directory> tempDir(String prefix) => Directory.systemTemp.createTemp('AppVault-$prefix-');
}

final _random = Random.secure();

String newUUID() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}'.toUpperCase();
}

String randomToken(int bytes) =>
    List<int>.generate(bytes, (_) => _random.nextInt(256)).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
