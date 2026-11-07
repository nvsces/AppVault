import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

import 'devices.dart';
import 'identity.dart';
import 'provisioning.dart';

/// Официальный App Store Connect API: регистрирует устройства и bundle ID, выпускает профили.
/// Ключ создаётся в App Store Connect → Users and Access → Integrations (роль Admin или Developer).
class ASCException implements Exception {
  ASCException(this.message);
  final String message;
  @override
  String toString() => message;

  static ASCException api(int status, String message) => ASCException('App Store Connect ($status): $message');
}

/// Ресурс JSON:API: `{id, type, attributes}`.
class ASCResource {
  ASCResource(this.id, this.type, this.attributes);
  final String id;
  final String type;
  final Map<String, dynamic> attributes;

  String? operator [](String key) => attributes[key] as String?;

  factory ASCResource.fromJson(Map<String, dynamic> j) =>
      ASCResource(j['id'] as String, j['type'] as String, (j['attributes'] as Map<String, dynamic>?) ?? {});
}

class ASCClient {
  ASCClient({required String issuerID, required String keyID, required String privateKeyPEM, HttpClient? http})
    : issuerID = issuerID.trim(),
      keyID = keyID.trim(),
      _http = http ?? HttpClient() {
    try {
      _key = ECPrivateKey(privateKeyPEM.trim());
    } catch (_) {
      throw ASCException('Не удалось прочитать ключ .p8 — нужен файл AuthKey_XXXX.p8 из App Store Connect');
    }
  }

  final String issuerID;
  final String keyID;
  final HttpClient _http;
  late final ECPrivateKey _key;
  static final base = Uri.parse('https://api.appstoreconnect.apple.com/');

  /// JWT ES256 живёт 20 минут — максимум, который принимает Apple.
  /// Пустой issuer — индивидуальный ключ пользователя (`sub: user`), иначе ключ команды.
  String token() {
    final jwt = JWT(
      {'aud': 'appstoreconnect-v1', if (issuerID.isEmpty) 'sub': 'user' else 'iss': issuerID},
      header: {'kid': keyID, 'typ': 'JWT'},
    );
    return jwt.sign(_key, algorithm: JWTAlgorithm.ES256, expiresIn: const Duration(minutes: 20));
  }

  Future<Uint8List> _send(String method, String path, {Map<String, String>? query, Map<String, dynamic>? body}) async {
    final uri = base.resolve(path).replace(queryParameters: query == null || query.isEmpty ? null : query);
    final req = await _http.openUrl(method, uri);
    req.headers.set('Authorization', 'Bearer ${token()}');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode(body)));
    }
    final res = await req.close();
    final b = BytesBuilder(copy: false);
    await for (final chunk in res) {
      b.add(chunk);
    }
    final data = b.takeBytes();
    if (res.statusCode < 200 || res.statusCode >= 300) throw ASCException.api(res.statusCode, errorMessage(data));
    return data;
  }

  Future<List<ASCResource>> _get(String path, [Map<String, String>? query]) async {
    final j = jsonDecode(utf8.decode(await _send('GET', path, query: query))) as Map<String, dynamic>;
    return (j['data'] as List).cast<Map<String, dynamic>>().map(ASCResource.fromJson).toList();
  }

  Future<ASCResource> _create(String path, Map<String, dynamic> body) async {
    final j = jsonDecode(utf8.decode(await _send('POST', path, body: body))) as Map<String, dynamic>;
    return ASCResource.fromJson(j['data'] as Map<String, dynamic>);
  }

  /// Текст ошибок JSON:API: `{"errors":[{"title":…,"detail":…}]}`.
  static String errorMessage(List<int> data) {
    try {
      final obj = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final texts = (obj['errors'] as List).cast<Map<String, dynamic>>().map((e) => (e['detail'] ?? e['title'])?.toString());
      final joined = texts.whereType<String>().join('; ');
      if (joined.isNotEmpty) return joined;
    } catch (_) {}
    final text = utf8.decode(data, allowMalformed: true);
    return text.length > 300 ? text.substring(0, 300) : text;
  }

  // MARK: - Устройства

  Future<List<ASCResource>> devices() => _get('v1/devices', {'limit': '200'});

  /// Регистрирует устройство, если его ещё нет, и включает, если оно отключено.
  Future<ASCResource> ensureDevice(String udid, String name) async {
    final found = await _get('v1/devices', {'filter[udid]': udid, 'limit': '20'});
    final existing = found.where((d) => d['udid']?.toLowerCase() == udid.toLowerCase()).firstOrNull;
    if (existing != null) {
      if (existing['status'] == 'DISABLED') {
        await _send(
          'PATCH',
          'v1/devices/${existing.id}',
          body: {
            'data': {
              'type': 'devices',
              'id': existing.id,
              'attributes': {'status': 'ENABLED'},
            },
          },
        );
      }
      return existing;
    }
    final deviceName = name.isEmpty ? 'iPhone ${udid.substring(udid.length - 6)}' : (name.length > 50 ? name.substring(0, 50) : name);
    return _create('v1/devices', {
      'data': {
        'type': 'devices',
        'attributes': {'name': deviceName, 'udid': udid, 'platform': 'IOS'},
      },
    });
  }

  // MARK: - Bundle ID

  Future<ASCResource> ensureBundleID(String identifier) async {
    final found = await _get('v1/bundleIds', {'filter[identifier]': identifier, 'limit': '200'});
    final exact = found.where((b) => b['identifier'] == identifier).firstOrNull;
    if (exact != null) return exact;
    return _create('v1/bundleIds', {
      'data': {
        'type': 'bundleIds',
        'attributes': {'identifier': identifier, 'name': bundleName(identifier), 'platform': 'IOS'},
      },
    });
  }

  /// В названии App ID Apple допускает только буквы, цифры и пробелы.
  static String bundleName(String identifier) {
    final cleaned = identifier.split('').map((c) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(c) ? c : ' ').join();
    final name = 'AppVault $cleaned';
    return (name.length > 60 ? name.substring(0, 60) : name).trim();
  }

  // MARK: - Сертификаты и профили

  Future<List<ASCResource>> certificates({required bool development}) => _get('v1/certificates', {
    'filter[certificateType]': development ? 'DEVELOPMENT,IOS_DEVELOPMENT' : 'DISTRIBUTION,IOS_DISTRIBUTION',
    'limit': '200',
  });

  Future<List<ASCResource>> profiles(String bundleID) => _get('v1/bundleIds/$bundleID/profiles', {'limit': '200'});

  Future<ASCResource> createProfile({
    required String name,
    required String type,
    required String bundleID,
    required String certificateID,
    required List<String> deviceIDs,
  }) {
    return _create('v1/profiles', {
      'data': {
        'type': 'profiles',
        'attributes': {'name': name, 'profileType': type},
        'relationships': {
          'bundleId': {
            'data': {'type': 'bundleIds', 'id': bundleID},
          },
          'certificates': {
            'data': [
              {'type': 'certificates', 'id': certificateID},
            ],
          },
          'devices': {
            'data': [
              for (final id in deviceIDs) {'type': 'devices', 'id': id},
            ],
          },
        },
      },
    });
  }

  Future<void> deleteProfile(String id) async {
    await _send('DELETE', 'v1/profiles/$id');
  }
}

/// Источник профилей: вручную из добавленных файлов или автоматически через App Store Connect API.
abstract class ProfileProvider {
  bool get isAutomatic;
  Future<ProvisioningProfile> profile(String bundleID);
}

/// Автоматический режим: устройство регистрируется, под каждый bundle ID выпускается свой профиль
/// со всеми устройствами команды. Готовый профиль переиспользуется, пока он годен.
class AutomaticProfileProvider implements ProfileProvider {
  AutomaticProfileProvider(this.api, this.identity, this.targets, this.log);

  final ASCClient api;
  final SigningIdentity identity;
  final List<Device> targets;
  final void Function(String) log;
  String? _certificateID;
  List<String> _deviceIDs = [];

  @override
  bool get isAutomatic => true;
  String get _profileType => identity.isDistribution ? 'IOS_APP_ADHOC' : 'IOS_APP_DEVELOPMENT';

  Future<void> prepare() async {
    final certs = await api.certificates(development: !identity.isDistribution);
    final cert = certs.where((c) {
      final content = c['certificateContent'];
      return content != null && sha1Hex(base64.decode(content)) == identity.sha1;
    }).firstOrNull;
    if (cert == null) {
      throw ASCException('Сертификата ${identity.shortName} нет среди сертификатов команды в App Store Connect');
    }
    _certificateID = cert.id;
    for (final d in targets) {
      log('Регистрация устройства ${d.name}');
      await api.ensureDevice(d.udid, d.name);
    }
    const phones = {'IPHONE', 'IPAD', 'IPOD'};
    _deviceIDs = (await api.devices())
        .where(
          (d) =>
              (d['status'] ?? 'ENABLED') == 'ENABLED' &&
              (d['platform'] ?? 'IOS') == 'IOS' &&
              (d['deviceClass'] == null || phones.contains(d['deviceClass'])),
        )
        .map((d) => d.id)
        .toList();
    if (_deviceIDs.isEmpty) throw ASCException('В команде нет зарегистрированных устройств iOS');
  }

  @override
  Future<ProvisioningProfile> profile(String bundleID) async {
    if (_certificateID == null) await prepare();
    log('App ID $bundleID');
    final bundle = await api.ensureBundleID(bundleID);
    final name = 'AppVault $bundleID';
    final udids = targets.map((d) => d.udid);

    for (final existing in (await api.profiles(bundle.id)).where((pr) => pr['name'] == name)) {
      final content = existing['profileContent'];
      if (existing['profileState'] == 'ACTIVE' && content != null) {
        try {
          final pr = ProvisioningProfile.decode(base64.decode(content));
          if (pr.certificateSHA1s.contains(identity.sha1) &&
              udids.every(pr.includes) &&
              pr.expiration.isAfter(DateTime.now().add(const Duration(days: 7)))) {
            return pr;
          }
        } on ProfileException {
          // испорченный профиль — пересоздадим
        }
      }
      log('Пересоздаю профиль «$name»');
      await api.deleteProfile(existing.id);
    }

    log('Выпускаю профиль «$name»');
    final created = await api.createProfile(
      name: name,
      type: _profileType,
      bundleID: bundle.id,
      certificateID: _certificateID!,
      deviceIDs: _deviceIDs,
    );
    final content = created['profileContent'];
    if (content == null) throw ASCException.api(0, 'профиль создан без содержимого');
    return ProvisioningProfile.decode(base64.decode(content));
  }
}
