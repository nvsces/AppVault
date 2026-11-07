import 'dart:convert';
import 'dart:io';

import '../core/resigner.dart';

enum SigningMode {
  manual('Свои профили'),
  automatic('App Store Connect API');

  const SigningMode(this.title);
  final String title;
}

/// Настройки в `settings.json` рядом с библиотекой.
class AppSettings {
  SigningMode signingMode = SigningMode.manual;

  /// `null` — выбрать сертификат автоматически.
  String? identitySHA1;

  /// Профиль, закреплённый вручную; `null` — подбирать под каждый bundle ID.
  String? pinnedProfileUUID;
  ResignOptions options = ResignOptions();
  String ascIssuerID = '';
  String ascKeyID = '';
  String toolsDir = '';
  String extraScanFolders = '';
  String section = 'library';
  String? selectedDevice;

  static AppSettings load(String path) {
    final s = AppSettings();
    try {
      final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      s.signingMode = SigningMode.values.asNameMap()[j['signingMode']] ?? SigningMode.manual;
      s.identitySHA1 = j['identitySHA1'] as String?;
      s.pinnedProfileUUID = j['pinnedProfileUUID'] as String?;
      if (j['options'] is Map<String, dynamic>) s.options = ResignOptions.fromJson(j['options'] as Map<String, dynamic>);
      s.ascIssuerID = j['ascIssuerID'] as String? ?? '';
      s.ascKeyID = j['ascKeyID'] as String? ?? '';
      s.toolsDir = j['toolsDir'] as String? ?? '';
      s.extraScanFolders = j['extraScanFolders'] as String? ?? '';
      s.section = j['section'] as String? ?? 'library';
      s.selectedDevice = j['selectedDevice'] as String?;
    } catch (_) {
      // нет файла или он испорчен — настройки по умолчанию
    }
    return s;
  }

  void save(String path) {
    try {
      File(path).parent.createSync(recursive: true);
      File(path).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'signingMode': signingMode.name,
          'identitySHA1': identitySHA1,
          'pinnedProfileUUID': pinnedProfileUUID,
          'options': options.toJson(),
          'ascIssuerID': ascIssuerID,
          'ascKeyID': ascKeyID,
          'toolsDir': toolsDir,
          'extraScanFolders': extraScanFolders,
          'section': section,
          'selectedDevice': selectedDevice,
        }),
      );
    } on FileSystemException {
      // настройки не критичны: не удалось сохранить — останутся в памяти до выхода
    }
  }
}
