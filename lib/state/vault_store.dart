import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/asc.dart';
import '../core/devices.dart';
import '../core/identity.dart';
import '../core/ipa.dart';
import '../core/ipatool.dart';
import '../core/library.dart';
import '../core/paths.dart';
import '../core/provisioning.dart';
import '../core/resigner.dart';
import '../core/secrets.dart';
import '../core/subprocess.dart';
import '../core/tools.dart';
import '../core/zip.dart';
import 'job.dart';
import 'settings.dart';

class VaultException implements Exception {
  VaultException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum InstallMethod {
  resign('Переподписать и установить'),
  asIs('Установить как есть');

  const InstallMethod(this.title);
  final String title;
}

class VaultStore extends ChangeNotifier {
  VaultStore({AppPaths? paths, bool startPolling = true}) : paths = paths ?? AppPaths.standard() {
    settings = AppSettings.load(this.paths.settingsFile);
    storage = LibraryStorage(this.paths.library);
    secrets = SecretStore(this.paths.secrets);
    profileLibrary = ProfileLibrary(this.paths.profiles);
    identityLibrary = IdentityLibrary(this.paths.identities, secrets);
    Toolbox.customDir = settings.toolsDir;
    Toolbox.dataDir = this.paths.tools;
    _ensureIPAToolPassphrase();
    items = storage.load();
    selectedDeviceID = settings.selectedDevice;
    missingTools = Toolbox.missing;
    refreshSigning();
    if (startPolling) {
      _startDevicePolling();
      unawaited(refreshAccount());
    } else {
      devicesLoading = false;
      accountChecked = true;
    }
  }

  final AppPaths paths;
  late final AppSettings settings;
  late final LibraryStorage storage;
  late final SecretStore secrets;
  late final ProfileLibrary profileLibrary;
  late final IdentityLibrary identityLibrary;

  // Библиотека
  List<LibraryItem> items = [];

  // Устройства
  List<Device> devices = [];
  bool devicesLoading = true;
  String? selectedDeviceID;
  final Map<String, List<InstalledApp>> installedApps = {};
  final Map<String, Device> _deviceCache = {};
  final Map<String, DateTime> _lastSeen = {};
  Timer? _pollTimer;
  bool _polling = false;
  bool _disposed = false;

  // Подпись
  List<SigningIdentity> identities = [];
  List<ProvisioningProfile> profiles = [];
  bool get hasASCKey => secrets.get('asc-private-key') != null;

  // App Store
  StoreAccount? account;
  bool accountChecked = false;

  // Прочее
  List<Tool> missingTools = [];
  final List<Job> jobs = [];

  Device? get selectedDevice => devices.where((d) => d.udid == selectedDeviceID).firstOrNull ?? devices.firstOrNull;
  int get runningJobs => jobs.where((j) => j.isRunning).length;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    super.dispose();
  }

  void saveSettings() {
    settings.save(paths.settingsFile);
    _changed();
  }

  void selectDevice(String udid) {
    selectedDeviceID = udid;
    settings.selectedDevice = udid;
    saveSettings();
  }

  void setToolsDir(String dir) {
    settings.toolsDir = dir;
    Toolbox.customDir = dir;
    refreshTools();
    saveSettings();
  }

  void refreshTools() {
    missingTools = Toolbox.missing;
    _changed();
  }

  /// ipatool на Windows хранит токен в файле, зашифрованном паролем; без терминала пароль
  /// передаётся флагом. Пароль случайный, создаётся один раз и хранится под DPAPI.
  void _ensureIPAToolPassphrase() {
    var pass = secrets.get('ipatool-keychain');
    if (pass == null) {
      pass = randomToken(24);
      secrets.set('ipatool-keychain', pass);
    }
    IPATool.keychainPassphrase = pass;
  }

  // MARK: - Задачи

  Job run(String title, Future<void> Function(Job job) body) {
    final job = Job(title);
    jobs.insert(0, job);
    _changed();
    () async {
      try {
        await body(job);
        job.finish(JobState.succeeded);
      } on CancelledException {
        job.append('Отменено');
        job.finish(JobState.cancelled);
      } catch (e) {
        if (job.token.isCancelled) {
          job.append('Отменено');
          job.finish(JobState.cancelled);
        } else {
          job.append('Ошибка: $e');
          job.finish(JobState.failed, e.toString());
        }
      }
      _changed();
    }();
    return job;
  }

  void clearFinishedJobs() {
    jobs.removeWhere((j) => !j.isRunning);
    _changed();
  }

  // MARK: - Библиотека

  void importFiles(List<String> paths, {LibrarySource? source}) {
    for (final path in paths) {
      run('Импорт ${p.basename(path)}', (job) async {
        job.append('Разбор архива');
        final item = await storage.add(path, source ?? ImportedSource(path));
        addItem(item);
        job.append(
          'Добавлено: ${item.info.name} ${item.info.version} — '
          '${item.info.kind == IPAKind.appStore ? 'сборка App Store' : 'без шифрования'}',
        );
      });
    }
  }

  void addItem(LibraryItem item) {
    items.insert(0, item);
    storage.save(items);
    _changed();
  }

  Future<void> delete(Set<String> ids) async {
    for (final item in items.where((i) => ids.contains(i.id)).toList()) {
      await storage.remove(item);
    }
    items.removeWhere((i) => ids.contains(i.id));
    storage.save(items);
    _changed();
  }

  /// Проводник с выделенным файлом.
  void reveal(String path) {
    if (Platform.isWindows) {
      Process.run('explorer.exe', ['/select,', path]);
    } else if (Platform.isMacOS) {
      Process.run('open', ['-R', path]);
    }
  }

  void openFolder(String path) {
    Directory(path).createSync(recursive: true);
    Process.run(Platform.isWindows ? 'explorer.exe' : 'open', [path]);
  }

  // MARK: - Устройства

  /// Фоновый опрос раз в 5 секунд: iPhone по Wi‑Fi то появляется, то пропадает (пока спит),
  /// разовой проверки при запуске недостаточно.
  void _startDevicePolling() {
    Future<void> tick() async {
      await _pollDevices(force: false);
      devicesLoading = false;
      _changed();
    }

    unawaited(tick());
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => tick());
  }

  /// Ручное обновление: заново спрашивает у устройств модель, iOS и режим разработчика.
  Future<void> refreshDevices() async {
    devicesLoading = true;
    refreshTools();
    await _pollDevices(force: true);
    devicesLoading = false;
    _changed();
  }

  Future<void> _pollDevices({required bool force}) async {
    if (_polling) return;
    _polling = true;
    try {
      final seen = await DeviceClient.scan();
      final now = DateTime.now();
      for (final MapEntry(key: udid, value: connections) in seen.entries) {
        _lastSeen[udid] = now;
        final known = _deviceCache[udid];
        if (!force && known != null && known.productVersion.isNotEmpty) {
          _deviceCache[udid] = known.copyWith(connections: connections);
        } else {
          _deviceCache[udid] = await DeviceClient.describe(udid, connections);
        }
      }
      // Вынутый кабель — устройство пропадает сразу; по Wi‑Fi ждём 90 секунд: iPhone проснётся и вернётся.
      for (final MapEntry(key: udid, value: device) in _deviceCache.entries.toList()) {
        if (seen.containsKey(udid)) continue;
        final quiet = now.difference(_lastSeen[udid] ?? DateTime(1970));
        if ((device.connections.length == 1 && device.connections.contains(Connection.usb)) || quiet > const Duration(seconds: 90)) {
          _deviceCache.remove(udid);
          _lastSeen.remove(udid);
        } else if (device.connections.contains(Connection.usb)) {
          _deviceCache[udid] = device.copyWith(connections: {Connection.network});
        }
      }
      final list = DeviceClient.sorted(_deviceCache.values);
      if (!listEquals(list, devices)) {
        devices = list;
        _changed();
      }
      if (selectedDeviceID == null && devices.isNotEmpty) selectedDeviceID = devices.first.udid;
    } finally {
      _polling = false;
    }
  }

  Future<void> loadApps(Device device) async {
    installedApps[device.udid] = await DeviceClient.installedApps(device.udid, device.useNetwork);
    _changed();
  }

  void uninstall(InstalledApp app, Device device) {
    run('Удаление ${app.name} с ${device.name}', (job) async {
      await DeviceClient.uninstall(app.bundleID, device.udid, device.useNetwork, cancel: job.token);
      job.append('Удалено');
      try {
        await loadApps(device);
      } catch (_) {}
    });
  }

  void revealDeveloperMode(Device device) {
    run('Режим разработчика на ${device.name}', (job) async {
      await DeviceClient.revealDeveloperMode(device.udid, device.useNetwork);
      job.append('На iPhone: Настройки → Конфиденциальность и безопасность → Режим разработчика');
    });
  }

  void registerDevice(Device device) {
    run('Регистрация ${device.name} в аккаунте разработчика', (job) async {
      await ascClient().ensureDevice(device.udid, device.name);
      job.append('Устройство зарегистрировано. Профили с ним выпускаются при следующей переподписи.');
    });
  }

  // MARK: - Подпись

  void refreshSigning() {
    identities = identityLibrary.load();
    profiles = profileLibrary.loadAll();
    _changed();
  }

  Future<void> importIdentity(String path, String password) async {
    final id = await identityLibrary.import(path, password);
    refreshSigning();
    if (identities.length == 1) settings.identitySHA1 = null;
    saveSettings();
    if (!id.isValid) throw VaultException('Сертификат ${id.shortName} истёк');
  }

  void removeIdentity(SigningIdentity id) {
    identityLibrary.remove(id);
    if (settings.identitySHA1 == id.sha1) settings.identitySHA1 = null;
    refreshSigning();
    saveSettings();
  }

  ProvisioningProfile importProfile(String path) {
    final profile = profileLibrary.import(path);
    refreshSigning();
    return profile;
  }

  void removeProfile(ProvisioningProfile profile) {
    profileLibrary.remove(profile);
    if (settings.pinnedProfileUUID == profile.uuid) settings.pinnedProfileUUID = null;
    refreshSigning();
    saveSettings();
  }

  void saveASC({required String issuerID, required String keyID, String? keyPEM}) {
    if (keyPEM != null) {
      ASCClient(issuerID: issuerID, keyID: keyID, privateKeyPEM: keyPEM); // проверка ключа
      secrets.set('asc-private-key', keyPEM);
    }
    settings.ascIssuerID = issuerID.trim();
    settings.ascKeyID = keyID.trim();
    saveSettings();
  }

  void removeASCKey() {
    secrets.delete('asc-private-key');
    _changed();
  }

  ASCClient ascClient() {
    final pem = secrets.get('asc-private-key');
    if (settings.ascKeyID.isEmpty || pem == null) {
      throw VaultException('Режим App Store Connect API: укажите ключ на вкладке «Подпись»');
    }
    return ASCClient(issuerID: settings.ascIssuerID, keyID: settings.ascKeyID, privateKeyPEM: pem);
  }

  void testASC() {
    run('Проверка ключа App Store Connect', (job) async {
      final api = ascClient();
      final devices = await api.devices();
      final certs = await api.certificates(development: true);
      final local = identities.map((i) => i.sha1).toSet();
      final usable = certs.where((c) {
        final content = c['certificateContent'];
        return content != null && local.contains(sha1Hex(base64Decode(content)));
      }).length;
      job.append(
        'Доступ есть: устройств в команде — ${devices.length}, сертификатов разработки — ${certs.length}, '
        'из них добавлено в AppVault — $usable',
      );
      if (usable == 0) job.append('Ни один сертификат команды не добавлен в AppVault — подпись в этом режиме не сработает');
    });
  }

  /// Сертификат для подписи. Без явного выбора — тот, у которого есть годный профиль
  /// (лучше шаблон «*») с этим устройством; при равенстве — сертификат разработки с поздним сроком.
  SigningIdentity chooseIdentity(Device? device) {
    final valid = identities.where((i) => i.isValid).toList();
    final chosen = settings.identitySHA1;
    if (chosen != null) {
      return valid.where((i) => i.sha1 == chosen).firstOrNull ??
          (throw VaultException('Нет сертификата для подписи: выбранный сертификат истёк или удалён'));
    }
    if (valid.isEmpty) throw VaultException('Нет сертификата для подписи: добавьте .p12 на вкладке «Подпись»');
    if (settings.signingMode == SigningMode.automatic) {
      return valid.where((i) => i.isDevelopment).firstOrNull ?? valid.first;
    }
    return IdentityChooser.best(valid, profiles, device?.udid) ?? valid.first;
  }

  SigningIdentity? get chosenIdentity {
    try {
      return chooseIdentity(selectedDevice);
    } on VaultException {
      return null;
    }
  }

  Future<(ProfileProvider, String)> _provider(SigningIdentity identity, List<Device> targets, Job job) async {
    switch (settings.signingMode) {
      case SigningMode.manual:
        final team = identity.teamID ?? profiles.where((pr) => pr.certificateSHA1s.contains(identity.sha1)).firstOrNull?.teamID ?? '';
        return (
          ManualProfileProvider(profiles, identity.sha1, team, targets.map((d) => d.udid).toList(), pinnedUUID: settings.pinnedProfileUUID),
          team,
        );
      case SigningMode.automatic:
        final auto = AutomaticProfileProvider(ascClient(), identity, targets, job.append);
        await auto.prepare();
        return (auto, identity.teamID ?? '');
    }
  }

  /// Переподписывает IPA во временный файл.
  Future<ResignResult> _resign(LibraryItem item, List<Device> targets, Job job) async {
    if (settings.signingMode == SigningMode.manual) profiles = profileLibrary.loadAll();
    final identity = chooseIdentity(targets.firstOrNull);
    final password = identityLibrary.password(identity);
    if (password == null) throw VaultException('Пароль к сертификату ${identity.shortName} не найден — добавьте .p12 заново');
    job.append('Сертификат: ${identity.name}');
    final (provider, team) = await _provider(identity, targets, job);
    final out = await AppPaths.tempDir('signed');
    final resigner = Resigner(log: job.append, progress: (v) => job.setProgress(v * 0.6), cancel: job.token);
    return resigner.resign(
      ipa: storage.ipaPath(item),
      output: p.join(out.path, item.fileName),
      credentials: (p12: identity.p12Path, password: password),
      teamID: team,
      provider: provider,
      options: settings.options,
    );
  }

  // MARK: - Установка

  void install(LibraryItem item, Device device, InstallMethod method) {
    run('Установка ${item.info.name} на ${device.name}', (job) async {
      final need = item.info.minimumOS;
      if (need != null && device.productVersion.isNotEmpty && compareVersions(device.productVersion, need) < 0) {
        throw VaultException('Приложению нужна iOS $need, на устройстве ${device.productVersion}');
      }
      var ipa = storage.ipaPath(item);
      String? cleanup, sinf, metadata;
      try {
        if (item.info.kind == IPAKind.resignable && method == InstallMethod.resign) {
          final result = await _resign(item, [device], job);
          ipa = result.output;
          cleanup = p.dirname(result.output);
          final exp = result.expiration;
          if (exp != null) job.append('Подпись действует до ${exp.day}.${exp.month}.${exp.year}');
        } else if (item.info.kind == IPAKind.appStore) {
          final buyer = item.info.store?.purchaserAppleID;
          job.append(
            buyer != null
                ? 'Сборка App Store: на iPhone должен быть вход в App Store с $buyer'
                : 'Сборка App Store: на iPhone должен быть вход с Apple ID, которым приложение получено',
          );
          final license = await _extractLicense(item);
          sinf = license.sinf;
          metadata = license.metadata;
          cleanup = license.dir;
        }

        final base = job.progress ?? 0;
        job.append('Передача на ${device.name} (${device.connectionTitle})');
        await DeviceClient.install(
          ipa,
          device.udid,
          device.useNetwork,
          sinf: sinf,
          metadata: metadata,
          cancel: job.token,
          progress: (percent, status) {
            if (percent != null) {
              job.setProgress(base + (1 - base) * percent, status);
            } else {
              job.append(status);
            }
          },
        );
        job.append('Установлено');
        if (item.info.kind == IPAKind.resignable && device.developerMode == false) {
          job.append('Включите режим разработчика: Настройки → Конфиденциальность и безопасность → Режим разработчика');
        }
        try {
          await loadApps(device);
        } catch (_) {}
      } finally {
        if (cleanup != null) {
          try {
            await Directory(cleanup).delete(recursive: true);
          } catch (_) {}
        }
      }
    });
  }

  /// SINF и iTunesMetadata из архива во временную папку — для явной передачи ideviceinstaller.
  Future<({String? sinf, String? metadata, String dir})> _extractLicense(LibraryItem item) async {
    final zip = await ZipReader.open(storage.ipaPath(item));
    final dir = await AppPaths.tempDir('license');
    String? sinf, metadata;
    final info = item.info;
    final preferred = '${info.appPath}/SC_Info/${info.executable}.sinf';
    final entry =
        zip[preferred]?.name ?? zip.names.where((e) => e.startsWith('${info.appPath}/SC_Info/') && e.endsWith('.sinf')).firstOrNull;
    if (entry != null) {
      sinf = p.join(dir.path, 'app.sinf');
      await File(sinf).writeAsBytes(await zip.read(entry));
    }
    if (zip['iTunesMetadata.plist'] != null) {
      metadata = p.join(dir.path, 'iTunesMetadata.plist');
      await File(metadata).writeAsBytes(await zip.read('iTunesMetadata.plist'));
    }
    return (sinf: sinf, metadata: metadata, dir: dir.path);
  }

  /// Переподписанная копия сохраняется в библиотеку — её можно ставить повторно без подписи.
  void resignToLibrary(LibraryItem item) {
    run('Переподпись ${item.info.name}', (job) async {
      final targets = settings.signingMode == SigningMode.automatic ? devices : [?selectedDevice];
      final result = await _resign(item, targets, job);
      try {
        final added = await storage.add(result.output, ResignedSource(item.id, result.teamID), move: true);
        addItem(added);
        job.append('Готово: ${added.info.bundleID}');
      } finally {
        try {
          await Directory(p.dirname(result.output)).delete(recursive: true);
        } catch (_) {}
      }
    });
  }

  // MARK: - App Store

  Future<void> refreshAccount() async {
    account = Toolbox.path(Tool.ipatool) == null ? null : await IPATool.account();
    accountChecked = true;
    _changed();
  }

  void setAccount(StoreAccount? value) {
    account = value;
    _changed();
  }

  Future<void> logout() async {
    try {
      await IPATool.logout();
    } catch (_) {}
    account = null;
    _changed();
  }

  void download(int appID, String? bundleID, String name, {String? versionID}) {
    run('Скачивание $name${versionID != null ? ' (версия $versionID)' : ''}', (job) => _download(appID, bundleID, versionID, job));
  }

  /// Та же версия, что стоит на устройстве: ID приложения и версии берутся из его iTunesMetadata.
  void downloadInstalled(InstalledApp app, Device device) {
    run('Скачивание ${app.name} ${app.version} с ${device.name}', (job) async {
      job.append('Сведения App Store с ${device.name}');
      final info = await DeviceClient.storeMetadata(app.bundleID, device.udid, device.useNetwork);
      final appID = info?.metadata.itemID;
      if (info == null || appID == null) throw VaultException('${app.name} установлено не из App Store — скачать его нельзя');
      if (info.testFlight) throw VaultException('${app.name} — сборка TestFlight: ipatool скачивает только из App Store');
      final buyer = info.metadata.purchaserAppleID, me = account?.email;
      if (buyer != null && me != null && buyer.toLowerCase() != me.toLowerCase()) {
        job.append(
          'Получено с Apple ID $buyer, вход в App Store — $me: платное приложение скачается, '
          'только если оно есть и в этих покупках',
        );
      }
      await _download(appID, app.bundleID, info.metadata.externalVersionID?.toString(), job);
    });
  }

  Future<void> _download(int appID, String? bundleID, String? versionID, Job job) async {
    final dir = await AppPaths.tempDir('download');
    try {
      job.append('Запрос к App Store');
      final file = await IPATool.download(
        appID,
        bundleID,
        versionID,
        dir.path,
        cancel: job.token,
        onBytes: (bytes) => job.setProgress(null, 'Скачано ${formatSize(bytes)}'),
      );
      job.append('Скачано, разбор архива');
      final item = await storage.add(file, AppStoreSource(appID, versionID), move: true);
      addItem(item);
      job.append('В библиотеке: ${item.info.name} ${item.info.version}');
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// `17.2.1` против `17.10`: по числам, недостающие части — нули.
int compareVersions(String a, String b) {
  final x = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final y = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  for (var i = 0; i < (x.length > y.length ? x.length : y.length); i++) {
    final c = (i < x.length ? x[i] : 0).compareTo(i < y.length ? y[i] : 0);
    if (c != 0) return c;
  }
  return 0;
}

String formatSize(int bytes) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return u == 0 ? '$bytes Б' : '${v.toStringAsFixed(v < 10 ? 1 : 0).replaceAll('.', ',')} ${units[u]}';
}
