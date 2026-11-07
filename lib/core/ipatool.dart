import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ipa.dart';
import 'subprocess.dart';
import 'tools.dart';

class StoreApp {
  const StoreApp({
    required this.id,
    required this.bundleID,
    required this.name,
    required this.version,
    required this.price,
    this.purchaseDate,
  });

  final int id;
  final String bundleID;
  final String name;
  final String version;
  final double price;
  final DateTime? purchaseDate;
}

class StoreAccount {
  const StoreAccount(this.name, this.email);
  final String name;
  final String email;
}

class IPAToolException implements Exception {
  IPAToolException(this.raw);
  final String raw;
  @override
  String toString() => IPATool.humanize(raw);
}

sealed class LoginResult {
  const LoginResult();
}

class LoginSuccess extends LoginResult {
  const LoginSuccess(this.account);
  final StoreAccount account;
}

/// Apple отправила код на доверенные устройства — повторить вход с кодом.
class LoginNeedsCode extends LoginResult {
  const LoginNeedsCode();
}

/// Обёртка над ipatool: вход в App Store, поиск, покупки, версии, скачивание.
/// На Windows ipatool хранит токен в зашифрованном файле и без терминала требует пароль к нему —
/// AppVault создаёт его сам при первом запуске и хранит под защитой DPAPI.
class IPATool {
  static String? keychainPassphrase;

  /// Каждая строка stdout в режиме `--format json` — отдельный JSON-объект (zerolog).
  static Future<List<Map<String, dynamic>>> run(
    List<String> args, {
    Duration timeout = const Duration(minutes: 3),
    CancelToken? cancel,
  }) async {
    final tool = Toolbox.require(Tool.ipatool);
    final pass = keychainPassphrase;
    final r = await Subprocess.run(
      tool,
      [
        ...args,
        '--format',
        'json',
        '--non-interactive',
        if (Platform.isWindows && pass != null) ...['--keychain-passphrase', pass],
      ],
      timeout: timeout,
      cancel: cancel,
    );
    final objects = parseLines(r.out);
    final error = objects.where((o) => o['level'] == 'error').firstOrNull;
    if (error != null) {
      throw IPAToolException((error['error'] ?? error['message'] ?? 'ошибка ipatool').toString());
    }
    if (r.status != 0) throw IPAToolException(SubprocessException.summary(r.err.trim().isEmpty ? r.out : r.err));
    return objects;
  }

  static List<Map<String, dynamic>> parseLines(String text) {
    final out = <Map<String, dynamic>>[];
    for (final line in const LineSplitter().convert(text)) {
      try {
        final v = jsonDecode(line);
        if (v is Map<String, dynamic>) out.add(v);
      } on FormatException {
        continue;
      }
    }
    return out;
  }

  static Future<StoreAccount?> account() async {
    try {
      final objects = await run(['auth', 'info'], timeout: const Duration(seconds: 30));
      final o = objects.lastWhere((o) => o['success'] == true);
      return StoreAccount(o['name'] as String? ?? '', o['email'] as String? ?? '');
    } catch (_) {
      return null;
    }
  }

  static Future<LoginResult> login(String email, String password, String? code) async {
    final args = [
      'auth',
      'login',
      '-e',
      email,
      '-p',
      password,
      if (code != null && code.isNotEmpty) ...['--auth-code', code],
    ];
    // Первый вход ipatool готовит долго: «the first login may take a few minutes».
    final objects = await run(args, timeout: const Duration(minutes: 10));
    final ok = objects.where((o) => o['success'] == true).lastOrNull;
    if (ok != null) return LoginSuccess(StoreAccount(ok['name'] as String? ?? '', ok['email'] as String? ?? email));
    if (objects.any((o) => (o['message'] as String?)?.contains('2FA') ?? false)) return const LoginNeedsCode();
    throw IPAToolException('вход не выполнен');
  }

  static Future<void> logout() async {
    await run(['auth', 'revoke'], timeout: const Duration(seconds: 30));
  }

  static Future<List<StoreApp>> search(String term, {int limit = 25}) async {
    final objects = await run(['search', term, '--limit', '$limit'], timeout: const Duration(minutes: 1));
    return objects.expand(apps).toList();
  }

  /// Все покупки аккаунта, постранично. Удалённые из магазина приложения здесь тоже есть.
  static Future<List<StoreApp>> allPurchases({int perPage = 100, void Function(int done, int total)? onPage}) async {
    final all = <StoreApp>[];
    var page = 1;
    while (true) {
      final objects = await run(['list-purchases', '--page', '$page', '--max-results', '$perPage'], timeout: const Duration(minutes: 2));
      final o = objects.where((o) => o['apps'] != null).firstOrNull;
      if (o == null) break;
      final batch = apps(o);
      all.addAll(batch);
      final total = (o['totalCount'] as num?)?.toInt() ?? all.length;
      onPage?.call(all.length, total);
      if (batch.isEmpty || all.length >= total || batch.length < perPage) break;
      page++;
    }
    return all;
  }

  /// Покупка по bundle ID. Снятое с продажи приложение в магазине по bundle ID не находится,
  /// а в покупках остаётся — вместе с числовым ID, по которому его можно скачать.
  static Future<StoreApp> purchase(String bundleID) async {
    final found = (await allPurchases()).where((a) => a.bundleID.toLowerCase() == bundleID.toLowerCase()).firstOrNull;
    if (found == null) {
      throw IPAToolException(
        'В покупках этого Apple ID нет $bundleID. Если приложение получено с другим Apple ID, '
        'войдите под ним; если оно ещё продаётся — найдите его на вкладке «Поиск»',
      );
    }
    return found;
  }

  static List<StoreApp> apps(Map<String, dynamic> object) {
    final list = object['apps'];
    if (list is! List) return [];
    return [
      for (final a in list.whereType<Map<String, dynamic>>())
        if (a['id'] is num)
          StoreApp(
            id: (a['id'] as num).toInt(),
            bundleID: a['bundleID'] as String? ?? '',
            name: a['name'] as String? ?? '',
            version: a['version'] as String? ?? '',
            price: (a['price'] as num?)?.toDouble() ?? 0,
            purchaseDate: parseDate(a['purchaseDate']),
          ),
    ];
  }

  /// Числовой ID обязателен: снятое с продажи приложение по bundle ID не находится,
  /// а по ID ipatool скачивает его из покупок.
  static List<String> idArgs(int appID, String? bundleID) => [
    '-i',
    '$appID',
    if (bundleID != null && bundleID.isNotEmpty) ...['-b', bundleID],
  ];

  /// Внешние идентификаторы версий от старых к новым.
  static Future<List<String>> versions(int appID, String? bundleID) async {
    final objects = await run(['list-versions', ...idArgs(appID, bundleID)], timeout: const Duration(minutes: 2));
    final o = objects.where((o) => o['externalVersionIdentifiers'] != null).firstOrNull;
    return (o?['externalVersionIdentifiers'] as List? ?? const []).map((e) => '$e').toList();
  }

  static Future<({String display, DateTime? date})> versionMetadata(int appID, String? bundleID, String versionID) async {
    final objects = await run([
      'get-version-metadata',
      ...idArgs(appID, bundleID),
      '--external-version-id',
      versionID,
    ], timeout: const Duration(minutes: 1));
    final o = objects.where((o) => o['displayVersion'] != null).firstOrNull;
    if (o == null) throw IPAToolException('нет данных о версии');
    return (display: o['displayVersion'] as String? ?? '', date: parseDate(o['releaseDate']));
  }

  /// Скачивает в `directory`, по ходу сообщая размер уже скачанного. `purchase` — получить
  /// бесплатную лицензию, если её ещё нет (платные приложения так не купить).
  static Future<String> download(
    int appID,
    String? bundleID,
    String? versionID,
    String directory, {
    bool purchase = true,
    void Function(int bytes)? onBytes,
    CancelToken? cancel,
  }) async {
    await Directory(directory).create(recursive: true);
    final args = [
      'download',
      ...idArgs(appID, bundleID),
      '-o',
      '$directory${Platform.pathSeparator}',
      if (versionID != null && versionID.isNotEmpty) ...['--external-version-id', versionID],
      if (purchase) '--purchase',
    ];
    final watcher = Timer.periodic(const Duration(milliseconds: 500), (_) => onBytes?.call(directorySize(directory)));
    try {
      final objects = await run(args, timeout: const Duration(hours: 3), cancel: cancel);
      final path = objects.where((o) => o['output'] != null).lastOrNull?['output'] as String?;
      if (path == null) throw IPAToolException('ipatool не сообщил путь к файлу');
      return path;
    } finally {
      watcher.cancel();
    }
  }

  static int directorySize(String dir) {
    try {
      return Directory(dir).listSync().whereType<File>().fold(0, (sum, f) => sum + f.lengthSync());
    } on FileSystemException {
      return 0;
    }
  }

  /// Числовой ID из ссылки `apps.apple.com/ru/app/name/id123456789` или из самого числа.
  static int? parseAppID(String text) {
    final t = text.trim();
    final n = int.tryParse(t);
    if (n != null) return n;
    final m = RegExp(r'id(\d{5,})').firstMatch(t);
    return m == null ? null : int.parse(m.group(1)!);
  }

  /// `ru.winelab`, `com.google.ios.ytcreator`. Ссылки и числа сюда не попадают.
  static String? parseBundleID(String text) {
    final t = text.trim();
    return RegExp(r'^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$').hasMatch(t) ? t : null;
  }

  /// Сообщения ipatool — на понятном языке, исходный текст сохраняем.
  static String humanize(String message) {
    final m = message.toLowerCase();
    if (m.contains('keyring') || m.contains('failed to get account')) return 'Не выполнен вход в App Store ($message)';
    if (m.contains('passphrase')) return 'ipatool не открыл хранилище токена ($message). Войдите в App Store заново';
    if (m.contains('app not found') || m.contains('item is temporarily unavailable') || m.contains('not available')) {
      return 'Приложение не найдено или недоступно для этого аккаунта: $message. '
          'Снятые с продажи приложения скачиваются только по числовому ID и только если они есть в покупках.';
    }
    if (m.contains('password token expired')) return 'Сессия App Store истекла — войдите заново ($message)';
    if (m.contains('paid') || m.contains('price')) return 'Платное приложение нужно сначала купить в App Store ($message)';
    return message;
  }
}
