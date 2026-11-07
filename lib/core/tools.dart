import 'dart:io';

import 'package:path/path.dart' as p;

/// Внешние утилиты: работа с устройством — libimobiledevice, App Store — ipatool, подпись — rcodesign.
enum Tool {
  ipatool('ipatool', 'вход в App Store, покупки, скачивание версий'),
  ideviceinstaller('ideviceinstaller', 'установка и удаление приложений на iPhone'),
  ideviceId('idevice_id', 'список подключённых устройств'),
  ideviceinfo('ideviceinfo', 'модель и версия iOS'),
  idevicedevmodectl('idevicedevmodectl', 'режим разработчика на iPhone'),
  rcodesign('rcodesign', 'переподпись своим сертификатом');

  const Tool(this.command, this.purpose);
  final String command;
  final String purpose;

  String get fileName => Platform.isWindows ? '$command.exe' : command;
}

class ToolMissing implements Exception {
  ToolMissing(this.tool);
  final Tool tool;
  @override
  String toString() =>
      'Не найден ${tool.fileName}. Положите утилиты в папку tools рядом с AppVault или укажите папку в настройках '
      '(скрипт scripts\\fetch_tools.ps1 скачивает всё нужное)';
}

/// Где искать утилиты: папка из настроек, `tools` рядом с AppVault.exe, `tools` в папке данных, PATH.
class Toolbox {
  static String? customDir;
  static String? dataDir;

  static List<String> get directories {
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final pathVar = Platform.environment['PATH'] ?? Platform.environment['Path'] ?? '';
    final dirs = [
      if (customDir != null && customDir!.isNotEmpty) customDir!,
      p.join(exeDir, 'tools'),
      ?dataDir,
      ...pathVar.split(Platform.isWindows ? ';' : ':'),
      if (!Platform.isWindows) ...['/opt/homebrew/bin', '/usr/local/bin'],
    ];
    final seen = <String>{};
    return dirs.where((d) => d.isNotEmpty && seen.add(d)).toList();
  }

  static String? path(Tool tool) {
    for (final dir in directories) {
      final candidate = p.join(dir, tool.fileName);
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  static String require(Tool tool) => path(tool) ?? (throw ToolMissing(tool));

  static List<Tool> get missing => Tool.values.where((t) => path(t) == null).toList();
}
