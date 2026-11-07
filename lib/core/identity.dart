import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'paths.dart';
import 'provisioning.dart';
import 'secrets.dart';
import 'subprocess.dart';
import 'tools.dart';

/// Сертификат подписи с закрытым ключом — файл .p12 (на Mac: «Связка ключей» → экспорт).
/// Связки ключей на Windows нет, поэтому .p12 копируется в папку данных, а пароль к нему — в DPAPI.
class SigningIdentity {
  const SigningIdentity({required this.sha1, required this.name, this.teamID, this.expiration, required this.p12Path});

  final String sha1;
  final String name;
  final String? teamID;
  final DateTime? expiration;
  final String p12Path;

  bool get isValid => expiration == null || expiration!.isAfter(DateTime.now());
  bool get isDevelopment => name.startsWith('Apple Development') || name.startsWith('iPhone Developer');
  bool get isDistribution => name.startsWith('Apple Distribution') || name.startsWith('iPhone Distribution');

  String get shortName {
    final i = name.indexOf(':');
    return i < 0 ? name : name.substring(i + 1).trim();
  }

  String get secretName => 'p12-$sha1';

  factory SigningIdentity.fromJson(Map<String, dynamic> j, String p12Path) => SigningIdentity(
    sha1: j['sha1'] as String,
    name: j['name'] as String,
    teamID: j['teamID'] as String?,
    expiration: j['expiration'] == null ? null : DateTime.parse(j['expiration'] as String),
    p12Path: p12Path,
  );

  Map<String, dynamic> toJson() => {'sha1': sha1, 'name': name, 'teamID': teamID, 'expiration': expiration?.toUtc().toIso8601String()};
}

class IdentityException implements Exception {
  IdentityException(this.message);
  final String message;
  @override
  String toString() => message;
}

class IdentityLibrary {
  IdentityLibrary(this.directory, this.secrets);
  final String directory;
  final SecretStore secrets;

  List<SigningIdentity> load() {
    final dir = Directory(directory);
    if (!dir.existsSync()) return [];
    final out = <SigningIdentity>[];
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
      final p12 = '${f.path.substring(0, f.path.length - 5)}.p12';
      if (!File(p12).existsSync()) continue;
      try {
        out.add(SigningIdentity.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>, p12));
      } catch (_) {
        continue;
      }
    }
    out.sort((a, b) => (b.expiration ?? DateTime(2100)).compareTo(a.expiration ?? DateTime(2100)));
    return out;
  }

  String? password(SigningIdentity id) => secrets.get(id.secretName);

  /// Проверяет пароль и читает сертификат через rcodesign, затем сохраняет копию .p12.
  Future<SigningIdentity> import(String path, String password) async {
    final info = await analyze(path, password);
    await Directory(directory).create(recursive: true);
    final p12 = p.join(directory, '${info.sha1}.p12');
    await File(path).copy(p12);
    await File(p.join(directory, '${info.sha1}.json')).writeAsString(jsonEncode(info.toJson()));
    secrets.set(info.secretName, password);
    return SigningIdentity.fromJson(info.toJson(), p12);
  }

  void remove(SigningIdentity id) {
    for (final ext in ['p12', 'json']) {
      final f = File(p.join(directory, '${id.sha1}.$ext'));
      if (f.existsSync()) f.deleteSync();
    }
    secrets.delete(id.secretName);
  }

  static Future<SigningIdentity> analyze(String path, String password) async {
    final tool = Toolbox.require(Tool.rcodesign);
    final tmp = await AppPaths.tempDir('p12');
    try {
      final passFile = p.join(tmp.path, 'password');
      await File(passFile).writeAsString(password);
      final r = await Subprocess.run(tool, ['analyze-certificate', '--p12-file', path, '--p12-password-file', passFile]);
      if (r.status != 0) {
        final why = SubprocessException.summary(r.err.trim().isEmpty ? r.out : r.err);
        throw IdentityException('Не удалось открыть .p12 — неверный пароль или повреждённый файл ($why)');
      }
      final certs = parseAnalyze(r.out);
      final leaf = certs.where((c) => _isSigning(c.name)).firstOrNull ?? certs.firstOrNull;
      if (leaf == null) throw IdentityException('В .p12 нет сертификата');
      return SigningIdentity(sha1: leaf.sha1, name: leaf.name, teamID: leaf.teamID, expiration: leaf.expiration, p12Path: path);
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  static bool _isSigning(String name) =>
      ['Apple Development', 'Apple Distribution', 'iPhone Developer', 'iPhone Distribution'].any(name.startsWith);

  /// Вывод `rcodesign analyze-certificate`: блоки «# Certificate N» со строками «Ключ:  значение».
  static List<({String name, String sha1, String? teamID, DateTime? expiration})> parseAnalyze(String out) {
    final result = <({String name, String sha1, String? teamID, DateTime? expiration})>[];
    for (final block in out.split(RegExp(r'^# Certificate \d+', multiLine: true)).skip(1)) {
      final fields = <String, String>{};
      for (final line in const LineSplitter().convert(block)) {
        final m = RegExp(r'^([A-Za-z0-9 ?-]+):\s+(.*)$').firstMatch(line);
        if (m != null) fields[m.group(1)!.trim()] = m.group(2)!.trim();
      }
      final sha = fields['SHA-1 fingerprint'];
      if (sha == null) continue;
      final team = fields['Team ID'];
      result.add((
        name: fields['Subject CN'] ?? '',
        sha1: sha.toUpperCase(),
        teamID: team == null || team == '<missing>' ? null : team,
        expiration: DateTime.tryParse(fields['Not Valid After'] ?? ''),
      ));
    }
    return result;
  }
}

class IdentityChooser {
  /// Лучший сертификат для ручного режима: тот, у которого есть годный профиль с устройством
  /// (шаблон «*» лучше конкретного App ID), затем сертификат разработки, затем более поздний срок.
  static SigningIdentity? best(List<SigningIdentity> identities, List<ProvisioningProfile> profiles, String? udid) {
    (int, int, DateTime) score(SigningIdentity id) {
      final usable = profiles.where(
        (pr) =>
            pr.certificateSHA1s.contains(id.sha1) &&
            !pr.isExpired &&
            pr.isIOS &&
            pr.kind != ProfileKind.appStore &&
            (udid == null || pr.includes(udid)),
      );
      final coverage = usable.any((pr) => pr.bundlePattern == '*') ? 2 : (usable.isEmpty ? 0 : 1);
      return (coverage, id.isDevelopment ? 1 : 0, id.expiration ?? DateTime(1970));
    }

    int compare((int, int, DateTime) a, (int, int, DateTime) b) {
      if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      return a.$3.compareTo(b.$3);
    }

    final valid = identities.where((i) => i.isValid).toList();
    if (valid.isEmpty) return null;
    return valid.reduce((a, b) => compare(score(a), score(b)) >= 0 ? a : b);
  }
}
