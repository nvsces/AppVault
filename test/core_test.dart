import 'dart:convert';
import 'dart:typed_data';

import 'package:appvault/core/asc.dart';
import 'package:appvault/core/devices.dart';
import 'package:appvault/core/entitlements.dart';
import 'package:appvault/core/identity.dart';
import 'package:appvault/core/ipatool.dart';
import 'package:appvault/core/plist.dart';
import 'package:appvault/core/provisioning.dart';
import 'package:appvault/core/resigner.dart';
import 'package:appvault/core/subprocess.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

const _testKey = '''-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg0dGFsWDZ9Gi9J5Dx
FHI04OYYdUeVJHDkenMYBfh5RyChRANCAARpAi4ixGcSzT1rAG9OND2ecfr2OSOk
15ET6jGFiRDl+S10dKsZF9HqXVSea0XzJiisAnr9/w61ybsVFDhzIRWD
-----END PRIVATE KEY-----''';

const _testPublicKey = '''-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaQIuIsRnEs09awBvTjQ9nnH69jkj
pNeRE+oxhYkQ5fktdHSrGRfR6l1UnmtF8yYorAJ6/f8Otcm7FRQ4cyEVgw==
-----END PUBLIC KEY-----''';

void main() {
  group('права', () {
    final wildcard = <String, dynamic>{
      'application-identifier': 'TEAMID1234.*',
      'keychain-access-groups': ['TEAMID1234.*', 'com.apple.token'],
      'get-task-allow': true,
      'com.apple.developer.team-identifier': 'TEAMID1234',
    };

    test('остаётся только разрешённое профилем', () {
      final built = Entitlements.build(
        profile: wildcard,
        teamID: 'TEAMID1234',
        bundleID: 'com.bank.app',
        original: {
          'application-identifier': 'OTHERTEAM1.com.bank.app',
          'keychain-access-groups': ['OTHERTEAM1.com.bank.shared', 'com.apple.token'],
          'com.apple.security.application-groups': ['group.com.bank'],
          'aps-environment': 'production',
          'get-task-allow': false,
        },
      );
      final e = built.entitlements;
      expect(e['application-identifier'], 'TEAMID1234.com.bank.app');
      expect(e['com.apple.developer.team-identifier'], 'TEAMID1234');
      expect(e['get-task-allow'], true);
      expect(e['keychain-access-groups'], ['TEAMID1234.com.bank.app', 'TEAMID1234.com.bank.shared', 'com.apple.token']);
      expect(e.containsKey('com.apple.security.application-groups'), isFalse);
      expect(built.dropped, ['aps-environment', 'com.apple.security.application-groups']);
    });

    test('значения профиля ограничивают исходные', () {
      final profile = {
        ...wildcard,
        'aps-environment': 'development',
        'com.apple.developer.associated-domains': '*',
        'com.apple.security.application-groups': ['group.mine'],
      };
      final e = Entitlements.build(
        profile: profile,
        teamID: 'TEAMID1234',
        bundleID: 'x.y',
        original: {
          'aps-environment': 'production',
          'com.apple.developer.associated-domains': ['applinks:bank.ru'],
          'com.apple.security.application-groups': ['group.mine', 'group.other'],
        },
      ).entitlements;
      expect(e['aps-environment'], 'development');
      expect(e['com.apple.developer.associated-domains'], ['applinks:bank.ru']);
      expect(e['com.apple.security.application-groups'], ['group.mine']);
    });

    test('меняется только префикс команды', () {
      expect(Entitlements.retarget('ABCDE12345.group.x', 'TEAMID1234'), 'TEAMID1234.group.x');
      expect(Entitlements.retarget('com.apple.token', 'TEAMID1234'), 'com.apple.token');
      expect(Entitlements.retarget(r'$(AppIdentifierPrefix)shared', 'TEAMID1234'), 'TEAMID1234.shared');
    });
  });

  group('профили', () {
    test('точный App ID лучше шаблона', () async {
      final provider = ManualProfileProvider(
        [
          Fixtures.profile(uuid: 'W', appID: '*'),
          Fixtures.profile(uuid: 'P', appID: 'com.example.*'),
          Fixtures.profile(uuid: 'E', appID: 'com.example.app'),
        ],
        'CERT',
        'TEAMID1234',
        ['UDID-1'],
      );
      expect((await provider.profile('com.example.app')).uuid, 'E');
      expect((await provider.profile('com.example.other')).uuid, 'P');
      expect((await provider.profile('org.another')).uuid, 'W');
    });

    test('пропускаются истёкшие, чужие и без устройства', () async {
      final provider = ManualProfileProvider(
        [
          Fixtures.profile(uuid: 'X', appID: '*', expires: const Duration(seconds: -10)),
          Fixtures.profile(uuid: 'C', appID: '*', certs: ['OTHER']),
          Fixtures.profile(uuid: 'D', appID: '*', devices: ['UDID-2']),
          Fixtures.profile(uuid: 'G', appID: '*', expires: const Duration(days: 1)),
        ],
        'CERT',
        'TEAMID1234',
        ['UDID-1'],
      );
      expect((await provider.profile('a.b')).uuid, 'G');
    });

    test('нет устройства — понятная ошибка', () async {
      final provider = ManualProfileProvider(
        [
          Fixtures.profile(appID: '*', devices: ['OTHER']),
        ],
        'CERT',
        'TEAMID1234',
        ['UDID-1'],
      );
      await expectLater(provider.profile('a.b'), throwsA(isA<ResignException>()));
    });

    test('виды и шаблоны', () {
      expect(Fixtures.profile(appID: '*').kind, ProfileKind.development);
      expect(Fixtures.profile(appID: '*', getTaskAllow: false).kind, ProfileKind.adHoc);
      expect(Fixtures.profile(appID: '*', devices: []).kind, ProfileKind.appStore);
      expect(Fixtures.profile(appID: 'com.a.*').matches('com.a.b.c'), isTrue);
      expect(Fixtures.profile(appID: 'com.a.*').matches('com.ab'), isFalse);
    });

    test('разбор .mobileprovision', () {
      final cert = Uint8List.fromList(utf8.encode('certificate-der'));
      final pr = ProvisioningProfile.decode(Fixtures.mobileprovision(appID: 'com.x.*', certificates: [cert]));
      expect(pr.teamID, 'TEAMID1234');
      expect(pr.bundlePattern, 'com.x.*');
      expect(pr.devices, ['UDID-1']);
      expect(pr.certificateSHA1s, [sha1Hex(cert)]);
      expect(pr.isExpired, isFalse);
      expect(() => ProvisioningProfile.decode(Uint8List.fromList([1, 2, 3])), throwsA(isA<ProfileException>()));
    });
  });

  group('bundle ID и rcodesign', () {
    test('вложенные идентификаторы', () {
      expect(Resigner.remap('com.a.app', 'com.a.app', 'com.a.app.TEAM'), 'com.a.app.TEAM');
      expect(Resigner.remap('com.a.app.share', 'com.a.app', 'com.a.app.TEAM'), 'com.a.app.TEAM.share');
      expect(Resigner.remap('com.vendor.widget', 'com.a.app', 'com.a.app.TEAM'), 'com.a.app.TEAM.widget');
    });

    test('идентификатор по режиму', () {
      final o = ResignOptions();
      expect(Resigner.targetBundleID('a.b', 'T1', o, false), 'a.b');
      expect(Resigner.targetBundleID('a.b', 'T1', o, true), 'a.b.T1');
      o.bundleIDMode = BundleIDMode.suffix;
      expect(Resigner.targetBundleID('a.b.T1', 'T1', o, false), 'a.b.T1');
      o.customBundleID = 'my.own';
      expect(Resigner.targetBundleID('a.b', 'T1', o, true), 'my.own');
      expect(Resigner.isValidBundleID('com.example.app-1'), isTrue);
      expect(Resigner.isValidBundleID('com example'), isFalse);
    });

    test('области действия прав: разделитель системы внутри уровня, «/» между уровнями', () {
      expect(Resigner.scopeFor('PlugIns/Share.appex', separator: r'\'), r'PlugIns\Share.appex');
      expect(Resigner.scopeFor(r'Watch\W.app\PlugIns\C.appex', separator: r'\'), r'Watch\W.app/PlugIns\C.appex');
      expect(Resigner.scopeFor('PlugIns/Share.appex', separator: '/'), 'PlugIns/Share.appex');
    });

    test('аргументы rcodesign: относительные пути прав, без двоеточий диска', () {
      final args = Resigner.signArgs(
        appRelative: r'Payload\A.app',
        scopedEntitlements: ['@main:entitlements-1.plist', r'PlugIns\S.appex:entitlements-0.plist'],
        p12: r'C:\data\cert.p12',
        passwordFile: r'C:\tmp\p12-password',
      );
      expect(args, [
        'sign',
        '--p12-file',
        r'C:\data\cert.p12',
        '--p12-password-file',
        r'C:\tmp\p12-password',
        '--entitlements-xml-file',
        '@main:entitlements-1.plist',
        '--entitlements-xml-file',
        r'PlugIns\S.appex:entitlements-0.plist',
        r'Payload\A.app',
      ]);
    });

    test('сертификат из вывода rcodesign analyze-certificate', () {
      const out = '''
# Certificate 0

Subject CN:                  Apple Development: Dmitry (AB12CD34EF)
Issuer CN:                   Apple Worldwide Developer Relations Certification Authority
Subject is Issuer?:          false
Team ID:                     TEAMID1234
SHA-1 fingerprint:           0123456789abcdef0123456789abcdef01234567
SHA-256 fingerprint:         aa
Not Valid Before:            2025-01-01T00:00:00+00:00
Not Valid After:             2026-01-01T00:00:00+00:00
Signed by Apple?:            true

# Certificate 1

Subject CN:                  Apple Worldwide Developer Relations Certification Authority
Team ID:                     <missing>
SHA-1 fingerprint:           ffff
Not Valid After:             2030-01-01T00:00:00+00:00
''';
      final certs = IdentityLibrary.parseAnalyze(out);
      expect(certs.length, 2);
      expect(certs[0].name, 'Apple Development: Dmitry (AB12CD34EF)');
      expect(certs[0].sha1, '0123456789ABCDEF0123456789ABCDEF01234567');
      expect(certs[0].teamID, 'TEAMID1234');
      expect(certs[0].expiration, DateTime.utc(2026));
      expect(certs[1].teamID, isNull);
    });
  });

  group('разбор вывода утилит', () {
    test('ipatool: поиск и покупки', () {
      const out =
          '{"level":"info","count":2,"apps":[{"id":389801252,"bundleID":"com.burbn.instagram","name":"Instagram",'
          '"version":"400.0","price":0},{"id":1,"bundleID":"a.b","name":"B","version":"1","price":2.99,'
          '"purchaseDate":"2021-03-04T05:06:07Z"}],"time":"2026-10-17T23:00:00+03:00"}\nnot json';
      final apps = IPATool.apps(IPATool.parseLines(out).single);
      expect(apps.length, 2);
      expect(apps[0].id, 389801252);
      expect(apps[0].bundleID, 'com.burbn.instagram');
      expect(apps[1].price, 2.99);
      expect(apps[1].purchaseDate, DateTime.utc(2021, 3, 4, 5, 6, 7));
    });

    test('ID из ссылок и bundle ID', () {
      expect(IPATool.parseAppID('https://apps.apple.com/ru/app/sberbank/id492224193'), 492224193);
      expect(IPATool.parseAppID(' 492224193 '), 492224193);
      expect(IPATool.parseAppID('https://example.com'), isNull);
      expect(IPATool.parseBundleID(' ru.winelab '), 'ru.winelab');
      expect(IPATool.parseBundleID('https://apps.apple.com/ru/app/sberbank/id492224193'), isNull);
      expect(IPATool.parseBundleID('492224193'), isNull);
      expect(IPATool.parseBundleID('winelab'), isNull);
    });

    test('прогресс установки', () {
      final pr = DeviceClient.parseProgress('Install: CopyingApplication (45%)')!;
      expect(pr.percent, 0.45);
      expect(pr.status, 'CopyingApplication');
      expect(DeviceClient.parseProgress('Install: Complete')!.status, 'Complete');
      expect(DeviceClient.parseProgress("Copying 'x.ipa' to device... DONE."), isNull);
    });

    test('установленные приложения', () {
      const json =
          '[{"CFBundleIdentifier":"ru.a","CFBundleDisplayName":"","CFBundleName":"Яблоко",'
          '"CFBundleShortVersionString":"1.2","SignerIdentity":"Apple iPhone OS Application Signing"},'
          '{"CFBundleIdentifier":"com.b","CFBundleDisplayName":"Альфа","SignerIdentity":"Apple Development: X (Y)"}]';
      final apps = DeviceClient.parseInstalledApps(Uint8List.fromList(utf8.encode(json)));
      expect(apps.map((a) => a.name), ['Альфа', 'Яблоко']);
      expect(apps[1].isAppStore && !apps[0].isAppStore, isTrue);
    });

    test('установленные приложения из XML Windows-утилиты', () {
      final apps = DeviceClient.parseInstalledApps(
        Plist.toXmlBytes([
          {
            'CFBundleIdentifier': 'com.example.demo',
            'CFBundleDisplayName': 'Демо',
            'CFBundleShortVersionString': '1.2',
            'SignerIdentity': 'Apple iPhone OS Application Signing',
          },
        ]),
      );
      expect(apps.single.bundleID, 'com.example.demo');
      expect(apps.single.name, 'Демо');
      expect(apps.single.version, '1.2');
      expect(apps.single.isAppStore, isTrue);
      expect(DeviceClient.parseInstalledApps(Plist.toXmlBytes([])), isEmpty);
      expect(() => DeviceClient.parseInstalledApps(Uint8List.fromList(utf8.encode('ERROR: no device'))), throwsA(isA<DeviceException>()));
    });

    test('метаданные App Store установленного приложения', () {
      Map<String, dynamic> entry(String id, Map<String, dynamic>? meta) => {
        'CFBundleIdentifier': id,
        if (meta != null) 'iTunesMetadata': Plist.toXmlBytes(meta),
      };
      final data = Plist.toXmlBytes([
        entry('ru.winelab', {
          'itemId': 1458615930,
          'softwareVersionExternalIdentifier': 892637440,
          'com.apple.iTunesStore.downloadInfo': {
            'accountInfo': {'AppleID': 'me@example.com'},
          },
        }),
        entry('com.beta', {
          'itemId': 6747259030,
          'betaExternalVersionIdentifier': 1,
          'distributorInfo': {'distributorID': 'com.apple.TestFlight'},
        }),
        entry('com.dev', null),
      ]);
      final store = DeviceClient.parseStoreMetadata(data, 'ru.winelab')!;
      expect(store.metadata.itemID, 1458615930);
      expect(store.metadata.externalVersionID, 892637440);
      expect(store.metadata.purchaserAppleID, 'me@example.com');
      expect(store.testFlight, isFalse);
      expect(DeviceClient.parseStoreMetadata(data, 'com.beta')!.testFlight, isTrue);
      expect(DeviceClient.parseStoreMetadata(data, 'com.dev'), isNull);
      expect(DeviceClient.parseStoreMetadata(data, 'nope'), isNull);
    });

    test('режим разработчика', () {
      const out = 'Device                                      DeveloperMode\n00008110-000471041439401E                   enabled\n';
      expect(DeviceClient.parseDeveloperMode(out, '00008110-000471041439401E'), isTrue);
      expect(DeviceClient.parseDeveloperMode(out, 'nope'), isNull);
    });

    test('повторяются только обрывы связи', () async {
      expect(DeviceClient.isTransient(DeviceException('No device found with udid 00008110-000471041439401E.')), isTrue);
      expect(DeviceClient.isTransient(SubprocessException('ERROR: Device 00008110 not found!')), isTrue);
      expect(DeviceClient.isTransient(DeviceException('ApplicationVerificationFailed')), isFalse);
      var n = 0;
      await expectLater(
        DeviceClient.retrying(true, () async {
          n++;
          throw DeviceException('ApplicationVerificationFailed');
        }),
        throwsA(isA<DeviceException>()),
      );
      expect(n, 1);
    });

    test('строка ошибки из вывода', () {
      expect(SubprocessException.summary('progress\nERROR: real reason\nmore'), 'ERROR: real reason');
      expect(SubprocessException.summary('a\r\nlast line\r\n'), 'last line');
    });

    test('отмена во время запуска процесса не теряется', () {
      final token = CancelToken()..cancel();
      var stopped = false;
      token.onCancel(() => stopped = true);
      expect(stopped, isTrue);
      expect(token.check, throwsA(isA<CancelledException>()));
    });
  });

  group('App Store Connect', () {
    test('токен ES256 проверяется открытым ключом', () {
      final api = ASCClient(issuerID: 'issuer-1', keyID: 'KEY123', privateKeyPEM: _testKey);
      final token = api.token();
      final jwt = JWT.verify(token, ECPublicKey(_testPublicKey));
      expect(jwt.header?['kid'], 'KEY123');
      expect(jwt.header?['alg'], 'ES256');
      expect(jwt.payload['iss'], 'issuer-1');
      expect(jwt.payload['aud'], 'appstoreconnect-v1');
      expect((jwt.payload['exp'] as int) - (jwt.payload['iat'] as int), 1200);
      // Apple ждёт подпись в виде r‖s по 32 байта, а не DER.
      expect(base64Url.decode(base64Url.normalize(token.split('.')[2])).length, 64);
    });

    test('индивидуальный ключ — sub: user', () {
      final jwt = JWT.decode(ASCClient(issuerID: ' ', keyID: 'K', privateKeyPEM: _testKey).token());
      expect(jwt.payload['sub'], 'user');
      expect((jwt.payload as Map).containsKey('iss'), isFalse);
    });

    test('мусор вместо ключа', () {
      expect(() => ASCClient(issuerID: '', keyID: 'K', privateKeyPEM: 'nope'), throwsA(isA<ASCException>()));
    });

    test('название App ID — только буквы, цифры и пробелы', () {
      final name = ASCClient.bundleName('com.example-app.Привет_1');
      expect(name, 'AppVault com example app Привет 1');
      expect(RegExp(r'^[\p{L}\p{N} ]+$', unicode: true).hasMatch(name), isTrue);
    });

    test('текст ошибок JSON:API', () {
      expect(ASCClient.errorMessage(utf8.encode('{"errors":[{"title":"T","detail":"D1"},{"title":"T2"}]}')), 'D1; T2');
      expect(ASCClient.errorMessage(utf8.encode('plain')), 'plain');
    });
  });
}
