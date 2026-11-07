import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'asc.dart';
import 'entitlements.dart';
import 'macho.dart';
import 'plist.dart';
import 'provisioning.dart';
import 'subprocess.dart';
import 'tools.dart';
import 'zip.dart';

/// Как поступать с идентификатором бандла при переподписи.
enum BundleIDMode {
  /// Вручную — оставить; через App Store Connect — добавить суффикс команды:
  /// чужой bundle ID в своей команде не зарегистрировать.
  auto('Автоматически'),
  keep('Оставить исходный'),
  suffix('Добавить суффикс команды');

  const BundleIDMode(this.title);
  final String title;
}

class ResignOptions {
  ResignOptions({this.bundleIDMode = BundleIDMode.auto, this.customBundleID, this.removeExtensions = false, this.removeWatchApp = true});

  BundleIDMode bundleIDMode;

  /// Задать идентификатор явно (перекрывает режим).
  String? customBundleID;
  bool removeExtensions;

  /// Приложению для часов нужен отдельный профиль watchOS — по умолчанию убираем.
  bool removeWatchApp;

  factory ResignOptions.fromJson(Map<String, dynamic> j) => ResignOptions(
    bundleIDMode: BundleIDMode.values.asNameMap()[j['bundleIDMode']] ?? BundleIDMode.auto,
    customBundleID: j['customBundleID'] as String?,
    removeExtensions: j['removeExtensions'] as bool? ?? false,
    removeWatchApp: j['removeWatchApp'] as bool? ?? true,
  );

  Map<String, dynamic> toJson() => {
    'bundleIDMode': bundleIDMode.name,
    'customBundleID': customBundleID,
    'removeExtensions': removeExtensions,
    'removeWatchApp': removeWatchApp,
  };
}

class ResignException implements Exception {
  ResignException(this.message);
  final String message;
  @override
  String toString() => message;

  static ResignException encrypted(String name) => ResignException(
    '$name зашифрован FairPlay — это сборка из App Store. Её нельзя переподписать, '
    'но можно установить как есть на устройство с тем же Apple ID.',
  );

  static ResignException noProfile(String bundleID, String why) => ResignException('Нет подходящего профиля для $bundleID: $why');
}

/// Выбор из добавленных профилей: точный App ID лучше шаблона, у шаблонов — более длинный префикс.
class ManualProfileProvider implements ProfileProvider {
  ManualProfileProvider(this.profiles, this.identitySHA1, this.teamID, this.udids, {this.pinnedUUID});

  final List<ProvisioningProfile> profiles;
  final String identitySHA1;
  final String teamID;
  final List<String> udids;
  final String? pinnedUUID;

  @override
  bool get isAutomatic => false;

  @override
  Future<ProvisioningProfile> profile(String bundleID) async {
    final pinned = profiles.where((pr) => pr.uuid == pinnedUUID).firstOrNull;
    if (pinned != null && pinned.matches(bundleID)) return pinned;
    final forTeam = profiles.where((pr) => pr.teamID == teamID && pr.isIOS && !pr.isExpired && pr.kind != ProfileKind.appStore).toList();
    if (forTeam.isEmpty) throw ResignException.noProfile(bundleID, 'нет действующих профилей команды $teamID');
    final withCert = forTeam.where((pr) => pr.certificateSHA1s.contains(identitySHA1)).toList();
    if (withCert.isEmpty) throw ResignException.noProfile(bundleID, 'ни один профиль не включает выбранный сертификат');
    final matching = withCert.where((pr) => pr.matches(bundleID)).toList();
    if (matching.isEmpty) {
      throw ResignException.noProfile(
        bundleID,
        'нет профиля с таким App ID или шаблоном «*». Добавьте профиль или включите режим App Store Connect API',
      );
    }
    final withDevices = matching.where((pr) => udids.every(pr.includes)).toList();
    if (withDevices.isEmpty) {
      throw ResignException.noProfile(
        bundleID,
        'устройство не входит в профиль. Зарегистрируйте его (вкладка «Устройства») или включите режим App Store Connect API',
      );
    }
    return withDevices.reduce((a, b) {
      final s = a.specificity(bundleID).compareTo(b.specificity(bundleID));
      if (s != 0) return s > 0 ? a : b;
      return a.expiration.isAfter(b.expiration) ? a : b;
    });
  }
}

class ResignResult {
  ResignResult(this.output, this.bundleID, this.teamID, this.expiration, this.droppedEntitlements);
  final String output;
  final String bundleID;
  final String teamID;

  /// Подпись действует, пока жив самый короткий из использованных профилей.
  final DateTime? expiration;
  final Map<String, List<String>> droppedEntitlements;
}

/// Сертификат для подписи: .p12 и пароль к нему. `null` — ad-hoc (без профилей: проверка конвейера).
typedef SigningCredentials = ({String p12, String password});

/// Переподпись через rcodesign: распаковка, профили и права для каждого бандла, подпись, упаковка.
/// rcodesign сам подписывает вложенные бандлы и библиотеки изнутри наружу; права для расширений
/// передаются ему с областью действия — путём расширения внутри приложения.
class Resigner {
  Resigner({this.log, this.progress, this.cancel});

  final void Function(String)? log;
  final void Function(double)? progress;
  final CancelToken? cancel;

  Future<ResignResult> resign({
    required String ipa,
    required String output,
    required SigningCredentials? credentials,
    required String teamID,
    required ProfileProvider? provider,
    required ResignOptions options,
  }) async {
    final work = await Directory.systemTemp.createTemp('AppVault-resign-');
    try {
      log?.call('Распаковка ${p.basename(ipa)}');
      progress?.call(0.05);
      final skipped = await _extractInIsolate(ipa, work.path);
      for (final s in skipped) {
        log?.call('Пропущена символьная ссылка $s');
      }
      cancel?.check();
      final payload = Directory(p.join(work.path, 'Payload'));
      final app = payload.existsSync() ? payload.listSync().whereType<Directory>().where((d) => d.path.endsWith('.app')).firstOrNull : null;
      if (app == null) throw ResignException('В архиве нет приложения (Payload/*.app)');

      // Магазинные метаданные и лицензии к переподписанной копии не относятся.
      for (final junk in ['iTunesMetadata.plist', 'META-INF', 'iTunesArtwork', 'iTunesArtwork@2x']) {
        await _remove(p.join(work.path, junk));
      }
      if (options.removeWatchApp) {
        for (final dir in ['Watch', 'com.apple.WatchPlaceholder']) {
          if (await _remove(p.join(app.path, dir))) log?.call('Удаляю приложение для часов ($dir)');
        }
      }
      if (options.removeExtensions) {
        for (final dir in ['PlugIns', 'Extensions']) {
          if (await _remove(p.join(app.path, dir))) log?.call('Удаляю расширения ($dir)');
        }
      }

      final bundles = codeBundles(app.path);
      for (final b in bundles) {
        await _remove(p.join(b, 'SC_Info'));
        final probe = await MachO.probeFile(executable(b));
        if (probe is MachOSlices && probe.isEncrypted) throw ResignException.encrypted(p.basename(b));
      }

      // Идентификаторы: главный бандл и всё, что начинается с его префикса.
      final originalID = readPlist(p.join(app.path, 'Info.plist')).str('CFBundleIdentifier') ?? '';
      final newID = targetBundleID(originalID, teamID, options, provider?.isAutomatic ?? false);
      if (!isValidBundleID(newID)) throw ResignException('Недопустимый идентификатор бандла: $newID');
      if (newID != originalID) log?.call('Bundle ID: $originalID → $newID');
      for (final b in bundles) {
        rewriteBundleIDs(p.join(b, 'Info.plist'), originalID, newID);
      }

      final dropped = <String, List<String>>{};
      DateTime? expiration;
      final scoped = <String>[];
      for (final (index, b) in bundles.indexed) {
        cancel?.check();
        progress?.call(0.15 + 0.4 * index / bundles.length);
        final name = p.basename(b);
        final bundleID = readPlist(p.join(b, 'Info.plist')).str('CFBundleIdentifier') ?? newID;
        final original = await MachO.entitlements(executable(b));
        var entitlements = original;
        if (provider != null) {
          final profile = await provider.profile(bundleID);
          log?.call('$name: профиль «${profile.name}» до ${_date(profile.expiration)}');
          await File(p.join(b, 'embedded.mobileprovision')).writeAsBytes(profile.data);
          final built = Entitlements.build(profile: profile.entitlements, teamID: profile.teamID, bundleID: bundleID, original: original);
          entitlements = built.entitlements;
          if (built.dropped.isNotEmpty) {
            dropped[name] = built.dropped;
            log?.call('$name: профиль не разрешает ${built.dropped.join(', ')} — эти функции работать не будут');
          }
          if (expiration == null || profile.expiration.isBefore(expiration)) expiration = profile.expiration;
        } else {
          await _remove(p.join(b, 'embedded.mobileprovision'));
        }
        final entFile = 'entitlements-$index.plist';
        await File(p.join(work.path, entFile)).writeAsString(Plist.toXml(entitlements));
        scoped.add('${b == app.path ? '@main' : scopeFor(p.relative(b, from: app.path))}:$entFile');
      }

      final tool = Toolbox.require(Tool.rcodesign);
      String? passFile;
      if (credentials != null) {
        passFile = p.join(work.path, 'p12-password');
        await File(passFile).writeAsString(credentials.password);
      }
      log?.call('Подпись (rcodesign)');
      progress?.call(0.6);
      await Subprocess.check(
        tool,
        signArgs(
          appRelative: p.relative(app.path, from: work.path),
          scopedEntitlements: scoped,
          p12: credentials?.p12,
          passwordFile: passFile,
        ),
        cwd: work.path,
        timeout: const Duration(minutes: 30),
        cancel: cancel,
        onStderr: (line) {
          if (line.contains('error') || line.startsWith('signing') || line.startsWith('entering')) log?.call(line);
        },
      );
      if (passFile != null) await _remove(passFile);

      log?.call('Упаковка');
      progress?.call(0.85);
      await _remove(output);
      await Directory(p.dirname(output)).create(recursive: true);
      await _zipInIsolate(work.path, output);
      progress?.call(1);
      return ResignResult(output, newID, teamID, expiration, dropped);
    } finally {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
  }

  // Замыкание для Isolate.run создаётся в статической функции: в нём должны быть только строки,
  // а не контекст метода с колбэками журнала.
  static Future<List<String>> _extractInIsolate(String ipa, String dir) =>
      Isolate.run(() async => (await ZipReader.open(ipa)).extractAll(dir));

  static Future<void> _zipInIsolate(String root, String output) => Isolate.run(() => ZipWriter.zipDirectory(root, 'Payload', output));

  static Future<bool> _remove(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else {
      await File(path).delete();
    }
    return true;
  }

  static String _date(DateTime d) => '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

  static List<String> signArgs({
    required String appRelative,
    required List<String> scopedEntitlements,
    String? p12,
    String? passwordFile,
  }) => [
    'sign',
    if (p12 != null) ...['--p12-file', p12, '--p12-password-file', passwordFile!],
    for (final e in scopedEntitlements) ...['--entitlements-xml-file', e],
    appRelative,
  ];

  /// Область действия для rcodesign: путь вложенного бандла относительно приложения.
  /// Внутри одного уровня rcodesign берёт путь с разделителем системы, между уровнями вложенности — «/».
  static String scopeFor(String relative, {String? separator}) {
    final sep = separator ?? Platform.pathSeparator;
    final parts = relative.split(RegExp(r'[\\/]'));
    final levels = <String>[];
    var current = <String>[];
    for (final part in parts) {
      current.add(part);
      if (part.endsWith('.app') || part.endsWith('.appex') || part.endsWith('.framework')) {
        levels.add(current.join(sep));
        current = [];
      }
    }
    if (current.isNotEmpty) levels.add(current.join(sep));
    return levels.join('/');
  }

  /// Бандлы с исполняемым кодом и своим профилем: приложение, его расширения и вложенные приложения.
  /// Порядок — изнутри наружу, главный бандл последним.
  static List<String> codeBundles(String bundle) {
    final out = <String>[];
    for (final sub in ['PlugIns', 'Extensions', 'Watch', 'AppClips']) {
      final dir = Directory(p.join(bundle, sub));
      if (!dir.existsSync()) continue;
      final children = dir.listSync().whereType<Directory>().map((d) => d.path).toList()..sort();
      for (final child in children) {
        if (child.endsWith('.appex') || child.endsWith('.app')) out.addAll(codeBundles(child));
      }
    }
    out.add(bundle);
    return out;
  }

  static String executable(String bundle) {
    final info = readPlist(p.join(bundle, 'Info.plist'));
    return p.join(bundle, info.str('CFBundleExecutable') ?? p.basenameWithoutExtension(bundle));
  }

  static Map<String, dynamic> readPlist(String path) => Plist.parseDict(File(path).readAsBytesSync());

  static String targetBundleID(String original, String teamID, ResignOptions options, bool automatic) {
    final custom = options.customBundleID?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    final suffixed = original.endsWith('.$teamID') ? original : '$original.$teamID';
    return switch (options.bundleIDMode) {
      BundleIDMode.keep => original,
      BundleIDMode.suffix => suffixed,
      BundleIDMode.auto => automatic ? suffixed : original,
    };
  }

  static bool isValidBundleID(String id) => RegExp(r'^[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)+$').hasMatch(id);

  /// `old` → `new`, `old.share` → `new.share`. Расширение с посторонним префиксом
  /// всё равно должно начинаться с идентификатора приложения — переносим его под новый.
  static String remap(String id, String old, String next) {
    if (id == old) return next;
    if (id.startsWith('$old.')) return next + id.substring(old.length);
    if (old == next) return id;
    return '$next.${id.split('.').last}';
  }

  static void rewriteBundleIDs(String plistPath, String old, String next) {
    if (old == next) return;
    final plist = readPlist(plistPath);
    final id = plist.str('CFBundleIdentifier');
    if (id != null) plist['CFBundleIdentifier'] = remap(id, old, next);
    final companion = plist.str('WKCompanionAppBundleIdentifier');
    if (companion != null) plist['WKCompanionAppBundleIdentifier'] = remap(companion, old, next);
    final attrs = plist.dict('NSExtension')?.dict('NSExtensionAttributes');
    final watch = attrs?.str('WKAppBundleIdentifier');
    if (attrs != null && watch != null) attrs['WKAppBundleIdentifier'] = remap(watch, old, next);
    File(plistPath).writeAsStringSync(Plist.toXml(plist));
  }
}
