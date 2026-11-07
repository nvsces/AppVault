import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'plist.dart';

String sha1Hex(List<int> data) => sha1.convert(data).toString().toUpperCase();

enum ProfileKind {
  development('Development'),
  adHoc('Ad Hoc'),
  appStore('App Store'),
  enterprise('Enterprise');

  const ProfileKind(this.title);
  final String title;
}

class ProfileException implements Exception {
  ProfileException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Профиль обеспечения (.mobileprovision): какой команде, каким App ID, устройствам и сертификатам
/// разрешено ставить приложение и с какими правами.
class ProvisioningProfile {
  ProvisioningProfile({
    required this.uuid,
    required this.name,
    required this.teamID,
    required this.teamName,
    required this.applicationIdentifier,
    required this.entitlements,
    required this.devices,
    required this.provisionsAllDevices,
    required this.certificateSHA1s,
    required this.creation,
    required this.expiration,
    required this.platforms,
    required this.data,
    this.filePath,
  });

  final String uuid;
  final String name;
  final String teamID;
  final String teamName;
  final String applicationIdentifier;
  final Map<String, dynamic> entitlements;
  final List<String> devices;
  final bool provisionsAllDevices;
  final List<String> certificateSHA1s;
  final DateTime creation;
  final DateTime expiration;
  final List<String> platforms;

  /// Исходный файл целиком — он же кладётся в бандл как embedded.mobileprovision.
  final Uint8List data;
  final String? filePath;

  ProfileKind get kind {
    if (provisionsAllDevices) return ProfileKind.enterprise;
    if (devices.isEmpty) return ProfileKind.appStore;
    return getTaskAllow ? ProfileKind.development : ProfileKind.adHoc;
  }

  /// Часть App ID после префикса команды: `com.example.app`, `com.example.*` или `*`.
  String get bundlePattern {
    final prefix = '$teamID.';
    if (applicationIdentifier.startsWith(prefix)) return applicationIdentifier.substring(prefix.length);
    final dot = applicationIdentifier.indexOf('.');
    return dot < 0 ? applicationIdentifier : applicationIdentifier.substring(dot + 1);
  }

  bool get isWildcard => bundlePattern.endsWith('*');
  bool get getTaskAllow => entitlements['get-task-allow'] == true;
  bool get isExpired => !expiration.isAfter(DateTime.now());
  bool get isIOS => platforms.isEmpty || platforms.contains('iOS');

  bool matches(String bundleID) {
    final pattern = bundlePattern;
    if (pattern == '*') return true;
    if (pattern.endsWith('*')) return bundleID.startsWith(pattern.substring(0, pattern.length - 1));
    return pattern == bundleID;
  }

  /// Чем точнее App ID, тем лучше: точное совпадение важнее любого шаблона.
  int specificity(String bundleID) => bundlePattern == bundleID ? 100000 : bundlePattern.length;

  bool includes(String udid) => provisionsAllDevices || devices.any((d) => d.toLowerCase() == udid.toLowerCase());

  /// Профиль — это plist, завёрнутый в подписанное CMS-сообщение; содержимое лежит в нём открытым текстом.
  static Uint8List? cmsContent(Uint8List data) {
    final text = latin1.decode(data);
    final start = text.indexOf('<?xml');
    final end = text.indexOf('</plist>', start < 0 ? 0 : start);
    if (start < 0 || end < 0) return null;
    return data.sublist(start, end + '</plist>'.length);
  }

  static ProvisioningProfile decode(Uint8List data, {String? path}) {
    final name = path != null ? p.basename(path) : 'profile';
    final content = cmsContent(data);
    if (content == null) throw ProfileException('Не удалось прочитать профиль $name');
    final Map<String, dynamic> d;
    try {
      d = Plist.parseDict(content);
    } on FormatException {
      throw ProfileException('Не удалось прочитать профиль $name');
    }
    final ent = d.dict('Entitlements') ?? {};
    final teams = d.list('TeamIdentifier')?.whereType<String>().toList() ?? const [];
    return ProvisioningProfile(
      uuid: d.str('UUID') ?? name,
      name: d.str('Name') ?? name,
      teamID: teams.firstOrNull ?? ent.str('com.apple.developer.team-identifier') ?? '',
      teamName: d.str('TeamName') ?? '',
      applicationIdentifier: ent.str('application-identifier') ?? '',
      entitlements: ent,
      devices: d.list('ProvisionedDevices')?.whereType<String>().toList() ?? const [],
      provisionsAllDevices: d.flag('ProvisionsAllDevices') ?? false,
      certificateSHA1s: (d.list('DeveloperCertificates') ?? const []).whereType<Uint8List>().map(sha1Hex).toList(),
      creation: d['CreationDate'] is DateTime ? d['CreationDate'] as DateTime : DateTime.utc(1970),
      expiration: d['ExpirationDate'] is DateTime ? d['ExpirationDate'] as DateTime : DateTime.utc(1970),
      platforms: d.list('Platform')?.whereType<String>().toList() ?? const [],
      data: data,
      filePath: path,
    );
  }
}

/// Профили, добавленные вручную: Xcode на Windows нет, поэтому своя папка.
class ProfileLibrary {
  ProfileLibrary(this.directory);
  final String directory;

  List<ProvisioningProfile> loadAll() {
    final dir = Directory(directory);
    if (!dir.existsSync()) return [];
    final seen = <String>{};
    final result = <ProvisioningProfile>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.mobileprovision')) continue;
      try {
        final profile = ProvisioningProfile.decode(f.readAsBytesSync(), path: f.path);
        if (seen.add(profile.uuid)) result.add(profile);
      } on ProfileException {
        continue;
      }
    }
    result.sort((a, b) {
      final c = a.teamID.compareTo(b.teamID);
      if (c != 0) return c;
      final n = a.name.compareTo(b.name);
      return n != 0 ? n : b.expiration.compareTo(a.expiration);
    });
    return result;
  }

  ProvisioningProfile import(String path) {
    final data = File(path).readAsBytesSync();
    final profile = ProvisioningProfile.decode(data, path: path);
    Directory(directory).createSync(recursive: true);
    final dest = p.join(directory, '${profile.uuid}.mobileprovision');
    File(dest).writeAsBytesSync(data);
    return ProvisioningProfile.decode(data, path: dest);
  }

  void remove(ProvisioningProfile profile) {
    final path = profile.filePath;
    if (path != null && p.isWithin(directory, path)) File(path).deleteSync();
  }
}
