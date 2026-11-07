import 'dart:convert';
import 'dart:typed_data';

import 'ipa.dart';
import 'plist.dart';
import 'subprocess.dart';
import 'tools.dart';

enum Connection { usb, network }

class Device {
  const Device({
    required this.udid,
    required this.name,
    required this.productType,
    required this.productVersion,
    required this.buildVersion,
    required this.connections,
    this.developerMode,
  });

  final String udid;
  final String name;
  final String productType;
  final String productVersion;
  final String buildVersion;
  final Set<Connection> connections;

  /// Режим разработчика (iOS 16+): без него приложения, подписанные своим сертификатом, не запускаются.
  final bool? developerMode;

  /// По кабелю быстрее и надёжнее — сеть только если кабеля нет.
  bool get useNetwork => !connections.contains(Connection.usb);
  String get modelName => models[productType] ?? productType;
  String get connectionTitle => connections.contains(Connection.usb) ? 'USB' : 'Wi‑Fi';

  Device copyWith({Set<Connection>? connections}) => Device(
    udid: udid,
    name: name,
    productType: productType,
    productVersion: productVersion,
    buildVersion: buildVersion,
    connections: connections ?? this.connections,
    developerMode: developerMode,
  );

  @override
  bool operator ==(Object other) =>
      other is Device &&
      other.udid == udid &&
      other.name == name &&
      other.productVersion == productVersion &&
      other.developerMode == developerMode &&
      other.connections.length == connections.length &&
      other.connections.containsAll(connections);

  @override
  int get hashCode => Object.hash(udid, name, productVersion, developerMode, connections.length);

  static const models = {
    'iPhone12,1': 'iPhone 11',
    'iPhone12,3': 'iPhone 11 Pro',
    'iPhone12,5': 'iPhone 11 Pro Max',
    'iPhone12,8': 'iPhone SE (2nd gen)',
    'iPhone13,1': 'iPhone 12 mini',
    'iPhone13,2': 'iPhone 12',
    'iPhone13,3': 'iPhone 12 Pro',
    'iPhone13,4': 'iPhone 12 Pro Max',
    'iPhone14,4': 'iPhone 13 mini',
    'iPhone14,5': 'iPhone 13',
    'iPhone14,2': 'iPhone 13 Pro',
    'iPhone14,3': 'iPhone 13 Pro Max',
    'iPhone14,6': 'iPhone SE (3rd gen)',
    'iPhone14,7': 'iPhone 14',
    'iPhone14,8': 'iPhone 14 Plus',
    'iPhone15,2': 'iPhone 14 Pro',
    'iPhone15,3': 'iPhone 14 Pro Max',
    'iPhone15,4': 'iPhone 15',
    'iPhone15,5': 'iPhone 15 Plus',
    'iPhone16,1': 'iPhone 15 Pro',
    'iPhone16,2': 'iPhone 15 Pro Max',
    'iPhone17,1': 'iPhone 16 Pro',
    'iPhone17,2': 'iPhone 16 Pro Max',
    'iPhone17,3': 'iPhone 16',
    'iPhone17,4': 'iPhone 16 Plus',
    'iPhone17,5': 'iPhone 16e',
  };
}

class InstalledApp {
  const InstalledApp({required this.bundleID, required this.name, required this.version, this.signer});
  final String bundleID;
  final String name;
  final String version;
  final String? signer;

  bool get isAppStore => signer == 'Apple iPhone OS Application Signing';
}

class DeviceException implements Exception {
  DeviceException(this.message, [this.hint]);
  final String message;
  final String? hint;
  @override
  String toString() => hint == null ? message : '$message\n$hint';
}

class DeviceClient {
  /// Какие устройства видны прямо сейчас. По Wi‑Fi iPhone виден через службу Apple Mobile Device
  /// и пропадает, пока экран погашен, — поэтому список опрашивается регулярно, а не один раз.
  static Future<Map<String, Set<Connection>>> scan() async {
    final tool = Toolbox.path(Tool.ideviceId);
    if (tool == null) return {};
    final results = await Future.wait([
      _quiet(() => Subprocess.run(tool, ['-l'], timeout: const Duration(seconds: 15))),
      _quiet(() => Subprocess.run(tool, ['-n'], timeout: const Duration(seconds: 15))),
    ]);
    final connections = <String, Set<Connection>>{};
    for (final udid in parseUDIDs(results[0]?.out ?? '')) {
      (connections[udid] ??= {}).add(Connection.usb);
    }
    for (final udid in parseUDIDs(results[1]?.out ?? '')) {
      (connections[udid] ??= {}).add(Connection.network);
    }
    return connections;
  }

  static Future<SubprocessResult?> _quiet(Future<SubprocessResult> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return null;
    }
  }

  /// Имя, модель, версия iOS и режим разработчика. Если устройство не ответило, `productVersion` пуст.
  static Future<Device> describe(String udid, Set<Connection> connections) async {
    final network = !connections.contains(Connection.usb);
    Map<String, dynamic> info = {};
    try {
      info = await retrying(network, () => DeviceClient.info(udid, network));
    } catch (_) {}
    return Device(
      udid: udid,
      name: info.str('DeviceName') ?? udid,
      productType: info.str('ProductType') ?? '',
      productVersion: info.str('ProductVersion') ?? '',
      buildVersion: info.str('BuildVersion') ?? '',
      connections: connections,
      developerMode: await developerMode(udid, network),
    );
  }

  static List<Device> sorted(Iterable<Device> devices) => devices.toList()
    ..sort((a, b) {
      final c = (a.useNetwork ? 1 : 0).compareTo(b.useNetwork ? 1 : 0);
      return c != 0 ? c : a.name.compareTo(b.name);
    });

  /// Устройство по Wi‑Fi может на секунду пропасть — такие сбои повторяем.
  static Future<T> retrying<T>(bool network, Future<T> Function() body, {int attempts = 4, CancelToken? cancel}) async {
    var attempt = 1;
    while (true) {
      try {
        return await body();
      } catch (e) {
        if (!network || attempt >= attempts || !isTransient(e)) rethrow;
        attempt++;
        await Future<void>.delayed(const Duration(seconds: 2));
        cancel?.check();
      }
    }
  }

  static bool isTransient(Object error) {
    final s = error.toString().toLowerCase();
    return s.contains('no device found') ||
        RegExp(r'device [^ ]* ?not found').hasMatch(s) ||
        s.contains('could not connect to lockdownd') ||
        s.contains('device removed') ||
        s.contains('превышено время');
  }

  static List<String> parseUDIDs(String output) =>
      output.split(RegExp(r'[\r\n]+')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  static List<String> baseArgs(String udid, bool network) => ['-u', udid, if (network) '-n'];

  static Future<Map<String, dynamic>> info(String udid, bool network) async {
    final tool = Toolbox.require(Tool.ideviceinfo);
    final r = await Subprocess.check(tool, [...baseArgs(udid, network), '-x'], timeout: const Duration(seconds: 20));
    try {
      return Plist.parseDict(r.stdout);
    } on FormatException {
      return {};
    }
  }

  static Future<bool?> developerMode(String udid, bool network) async {
    final tool = Toolbox.path(Tool.idevicedevmodectl);
    if (tool == null) return null;
    try {
      final r = await Subprocess.run(tool, [...baseArgs(udid, network), 'list'], timeout: const Duration(seconds: 15));
      return parseDeveloperMode(r.out, udid);
    } catch (_) {
      return null;
    }
  }

  /// Таблица `UDID  enabled|disabled`.
  static bool? parseDeveloperMode(String output, String udid) {
    for (final line in output.split(RegExp(r'[\r\n]+')).where((l) => l.contains(udid))) {
      final state = line.trim().split(RegExp(r'\s+')).last.toLowerCase();
      if (state == 'enabled') return true;
      if (state == 'disabled') return false;
    }
    return null;
  }

  static Future<void> revealDeveloperMode(String udid, bool network) async {
    final tool = Toolbox.require(Tool.idevicedevmodectl);
    await Subprocess.check(tool, [...baseArgs(udid, network), 'reveal'], timeout: const Duration(seconds: 30));
  }

  static Future<List<InstalledApp>> installedApps(String udid, bool network) async {
    final tool = Toolbox.require(Tool.ideviceinstaller);
    const attrs = ['CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleDisplayName', 'CFBundleName', 'SignerIdentity'];
    final r = await retrying(
      network,
      () => Subprocess.check(tool, [
        ...baseArgs(udid, network),
        'list',
        '--user',
        '--xml',
        for (final a in attrs) ...['-a', a],
      ], timeout: const Duration(minutes: 2)),
    );
    return parseInstalledApps(r.stdout);
  }

  static List<InstalledApp> parseInstalledApps(Uint8List data) {
    final List list;
    try {
      // The bundled Windows ideviceinstaller supports XML, but not --json.
      // Accept JSON too for newer user-supplied toolchains.
      final text = utf8.decode(data, allowMalformed: true).trimLeft();
      final decoded = text.startsWith('[') ? jsonDecode(text) : Plist.parse(data);
      if (decoded is! List) throw const FormatException('Expected an application list');
      list = decoded;
    } catch (_) {
      throw DeviceException('Не удалось прочитать список приложений: неожиданный ответ ideviceinstaller');
    }
    final apps = <InstalledApp>[];
    for (final d in list.whereType<Map<String, dynamic>>()) {
      final id = d.str('CFBundleIdentifier');
      if (id == null) continue;
      final display = d.str('CFBundleDisplayName');
      apps.add(
        InstalledApp(
          bundleID: id,
          name: (display != null && display.isNotEmpty ? display : null) ?? d.str('CFBundleName') ?? id,
          version: d.str('CFBundleShortVersionString') ?? '',
          signer: d.str('SignerIdentity'),
        ),
      );
    }
    apps.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return apps;
  }

  /// iTunesMetadata установленного приложения: числовой ID и ID версии нужны ipatool,
  /// чтобы скачать ту же сборку, что стоит на устройстве. `null` — приложение не из App Store.
  static Future<({StoreMetadata metadata, bool testFlight})?> storeMetadata(String bundleID, String udid, bool network) async {
    final tool = Toolbox.require(Tool.ideviceinstaller);
    final r = await retrying(
      network,
      () => Subprocess.check(tool, [
        ...baseArgs(udid, network),
        'list',
        '--xml',
        '-b',
        bundleID,
        '-a',
        'CFBundleIdentifier',
        '-a',
        'iTunesMetadata',
      ], timeout: const Duration(minutes: 1)),
    );
    return parseStoreMetadata(r.stdout, bundleID);
  }

  /// iTunesMetadata приходит вложенным plist в поле data. У сборок TestFlight вместо ID версии App Store — бета-версия.
  static ({StoreMetadata metadata, bool testFlight})? parseStoreMetadata(Uint8List data, String bundleID) {
    try {
      final list = Plist.parse(data);
      if (list is! List) return null;
      final entry = list.whereType<Map<String, dynamic>>().where((d) => d['CFBundleIdentifier'] == bundleID).firstOrNull;
      final raw = entry?['iTunesMetadata'];
      if (raw is! Uint8List) return null;
      final d = Plist.parseDict(raw);
      final distributor = d.dict('distributorInfo')?.str('distributorID');
      return (
        metadata: StoreMetadata.fromPlist(d),
        testFlight: distributor == 'com.apple.TestFlight' || d['betaExternalVersionIdentifier'] != null,
      );
    } on FormatException {
      return null;
    }
  }

  /// Установка IPA. Для сборок App Store лицензию (SINF) и iTunesMetadata передаём явно:
  /// ideviceinstaller ищет SINF по имени исполняемого файла и промахивается, если бандл назван иначе.
  static Future<void> install(
    String ipa,
    String udid,
    bool network, {
    String? sinf,
    String? metadata,
    required void Function(double? percent, String status) progress,
    CancelToken? cancel,
  }) async {
    final tool = Toolbox.require(Tool.ideviceinstaller);
    final args = [
      ...baseArgs(udid, network),
      'install',
      ipa,
      if (sinf != null) ...['-s', sinf],
      if (metadata != null) ...['-m', metadata],
    ];
    await retrying(network, cancel: cancel, () async {
      final errors = <String>[];
      final r = await Subprocess.run(
        tool,
        args,
        timeout: const Duration(minutes: 30),
        cancel: cancel,
        onStdout: (line) {
          final p = parseProgress(line);
          if (p != null) {
            progress(p.percent, p.status);
          } else {
            progress(null, line);
          }
        },
        onStderr: (line) {
          if (line.startsWith('ERROR') || line.contains('Could not')) errors.add(line);
          progress(null, line);
        },
      );
      final failure = errors.firstOrNull ?? (r.status != 0 ? SubprocessException.summary(r.err.trim().isEmpty ? r.out : r.err) : null);
      if (failure != null) throw DeviceException(failure, hint(failure));
    });
  }

  static Future<void> uninstall(String bundleID, String udid, bool network, {CancelToken? cancel}) async {
    final tool = Toolbox.require(Tool.ideviceinstaller);
    await retrying(network, cancel: cancel, () async {
      final r = await Subprocess.run(
        tool,
        [...baseArgs(udid, network), 'uninstall', bundleID],
        timeout: const Duration(minutes: 5),
        cancel: cancel,
      );
      if (r.status != 0 || r.err.contains('ERROR')) {
        throw DeviceException(SubprocessException.summary(r.err.trim().isEmpty ? r.out : r.err));
      }
    });
  }

  /// `Install: CopyingApplication (45%)` → (0.45, "CopyingApplication").
  static ({double? percent, String status})? parseProgress(String line) {
    final m = RegExp(r'^(?:Install|Upgrade|Uninstall): (\w+)(?: \((\d+)%\))?').firstMatch(line);
    if (m == null) return null;
    final pct = m.group(2);
    return (percent: pct == null ? null : int.parse(pct) / 100, status: m.group(1)!);
  }

  /// Подсказки к частым ошибкам installd.
  static String? hint(String error) {
    final e = error.toLowerCase();
    if (e.contains('0xe8008015') || e.contains('valid provisioning profile')) {
      return 'Устройство не входит в профиль. Зарегистрируйте его в аккаунте разработчика и переподпишите.';
    }
    if (e.contains('devicenotsupportedbythinning') || e.contains('incompatible')) {
      return 'Сборка не подходит этому устройству (архитектура или семейство iPhone/iPad).';
    }
    if (e.contains('mismatchedapplicationidentifierentitlement')) {
      return 'На устройстве уже есть приложение с таким bundle ID от другой команды. Удалите его или переподпишите с суффиксом.';
    }
    if (e.contains('applicationverificationfailed') || e.contains('0xe8008001')) {
      return 'iOS отклонила подпись: проверьте, что сертификат не отозван, а профиль не истёк.';
    }
    if (e.contains('deviceosversiontoolow') || e.contains('minimumosversion')) return 'Приложению нужна более новая iOS.';
    if (e.contains('could not connect to lockdownd')) {
      return 'Разблокируйте iPhone и подтвердите «Доверять этому компьютеру».';
    }
    if (e.contains('no device found')) {
      return 'Проверьте, что установлено приложение «Устройства Apple» (или iTunes) — без его службы Windows не видит iPhone.';
    }
    return null;
  }
}
