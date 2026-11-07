import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:appvault/core/plist.dart';
import 'package:appvault/core/png.dart';
import 'package:appvault/core/provisioning.dart';
import 'package:archive/archive_io.dart' show ZipFileEncoder;
import 'package:path/path.dart' as p;

/// Синтетические Mach-O, CgBI-PNG, профили и IPA для тестов.
class Fixtures {
  static Uint8List le32(int v) => (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
  static Uint8List be32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();

  /// Тонкий arm64 Mach-O: LC_UUID, (опционально) LC_ENCRYPTION_INFO_64 и подпись с правами.
  static Uint8List machO({int? cryptid, int cpu = 0x0100000C, Map<String, dynamic>? entitlements}) {
    final cmds = BytesBuilder()..add([...le32(0x1B), ...le32(24), ...List.filled(16, 0)]);
    var ncmds = 1;
    if (cryptid != null) {
      cmds.add([...le32(0x2C), ...le32(24), ...le32(0x4000), ...le32(0x1000), ...le32(cryptid), ...le32(0)]);
      ncmds++;
    }
    Uint8List? signature;
    if (entitlements != null) {
      final xml = utf8.encode(Plist.toXml(entitlements));
      final blob = [...be32(0xFADE7171), ...be32(8 + xml.length), ...xml];
      signature = Uint8List.fromList([...be32(0xFADE0CC0), ...be32(20 + blob.length), ...be32(1), ...be32(5), ...be32(20), ...blob]);
      ncmds++;
    }
    const headerSize = 32;
    final cmdsSize = cmds.length + (signature != null ? 16 : 0);
    final sigOffset = 4096;
    if (signature != null) cmds.add([...le32(0x1D), ...le32(16), ...le32(sigOffset), ...le32(signature.length)]);
    final out = BytesBuilder()
      ..add([...le32(0xFEEDFACF), ...le32(cpu), ...le32(0), ...le32(2), ...le32(ncmds), ...le32(cmdsSize), ...le32(0), ...le32(0)])
      ..add(cmds.takeBytes());
    final body = out.takeBytes();
    final padded = Uint8List(signature == null ? headerSize + cmdsSize + 256 : sigOffset + signature.length)
      ..setRange(0, body.length, body);
    if (signature != null) padded.setRange(sigOffset, sigOffset + signature.length, signature);
    return padded;
  }

  /// Толстый бинарник из нескольких срезов, каждый по смещению, кратному 4096.
  static Uint8List fat(List<Uint8List> slices) {
    final header = BytesBuilder()..add([...be32(0xCAFEBABE), ...be32(slices.length)]);
    final body = BytesBuilder();
    var offset = 4096;
    for (final s in slices) {
      header.add([...be32(0x0100000C), ...be32(0), ...be32(offset), ...be32(s.length), ...be32(12)]);
      body.add(List.filled(offset - (4096 + body.length), 0));
      body.add(s);
      offset = 4096 + ((body.length + 4095) ~/ 4096) * 4096;
    }
    final h = header.takeBytes();
    return Uint8List.fromList([...h, ...List.filled(4096 - h.length, 0), ...body.takeBytes()]);
  }

  /// PNG в формате Xcode «для iPhone»: чанк CgBI, BGRA с предумноженной альфой, сырой deflate.
  /// `pixels` — RGBA без предумножения, построчно. Вторая и далее строки сжимаются фильтром Up.
  static Uint8List cgbiPNG(int width, int height, List<int> pixels) {
    final raw = <int>[];
    var prev = List.filled(width * 4, 0);
    for (var y = 0; y < height; y++) {
      final row = <int>[];
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        final r = pixels[i], g = pixels[i + 1], b = pixels[i + 2], a = pixels[i + 3];
        row.addAll([b * a ~/ 255, g * a ~/ 255, r * a ~/ 255, a]);
      }
      raw.add(y == 0 ? 0 : 2);
      raw.addAll(y == 0 ? row : [for (var i = 0; i < row.length; i++) (row[i] - prev[i]) & 0xFF]);
      prev = row;
    }
    final compressed = ZLibEncoder(raw: true).convert(raw);
    List<int> chunk(String type, List<int> data) => [...be32(data.length), ...ascii.encode(type), ...data, ...be32(0)];
    return Uint8List.fromList([
      ...PngDecoder.signature,
      ...chunk('CgBI', [0x50, 0x00, 0x20, 0x06]),
      ...chunk('IHDR', [...be32(width), ...be32(height), 8, 6, 0, 0, 0]),
      ...chunk('IDAT', compressed),
      ...chunk('IEND', []),
    ]);
  }

  /// .mobileprovision: plist внутри «CMS» — для разбора важен только открытый текст между мусором.
  static Uint8List mobileprovision({
    String uuid = 'UUID-1',
    String appID = '*',
    String team = 'TEAMID1234',
    List<String> devices = const ['UDID-1'],
    List<Uint8List> certificates = const [],
    Duration expires = const Duration(days: 30),
    bool getTaskAllow = true,
    Map<String, dynamic> entitlements = const {},
  }) {
    final plist = {
      'UUID': uuid,
      'Name': 'Profile $appID',
      'TeamIdentifier': [team],
      'TeamName': 'Team',
      'CreationDate': DateTime.now().toUtc(),
      'ExpirationDate': DateTime.now().add(expires).toUtc(),
      'ProvisionedDevices': devices,
      'DeveloperCertificates': certificates,
      'Platform': ['iOS'],
      'Entitlements': {...entitlements, 'application-identifier': '$team.$appID', 'get-task-allow': getTaskAllow},
    };
    return Uint8List.fromList([0x30, 0x82, 0x01, 0x02, ...utf8.encode(Plist.toXml(plist)), 0xA0, 0x82, 0x00]);
  }

  static ProvisioningProfile profile({
    String uuid = 'UUID-1',
    required String appID,
    String team = 'TEAMID1234',
    List<String> devices = const ['UDID-1'],
    List<String> certs = const ['CERT'],
    Duration expires = const Duration(days: 30),
    bool getTaskAllow = true,
  }) => ProvisioningProfile(
    uuid: uuid,
    name: 'Profile $appID',
    teamID: team,
    teamName: 'Team',
    applicationIdentifier: '$team.$appID',
    entitlements: {'application-identifier': '$team.$appID', 'get-task-allow': getTaskAllow},
    devices: devices,
    provisionsAllDevices: false,
    certificateSHA1s: certs,
    creation: DateTime.now(),
    expiration: DateTime.now().add(expires),
    platforms: const ['iOS'],
    data: Uint8List.fromList(utf8.encode('profile-$uuid')),
  );

  static Future<Directory> tempDir(String name) => Directory.systemTemp.createTemp('AppVaultTests-$name-');

  static Future<void> write(String path, List<int> data) async {
    await Directory(p.dirname(path)).create(recursive: true);
    await File(path).writeAsBytes(data);
  }

  /// Пакует всё содержимое `dir` (Payload и то, что рядом) в zip.
  static Future<void> zip(String dir, String out) async {
    final encoder = ZipFileEncoder()..create(out);
    final files = Directory(dir).listSync(recursive: true).whereType<File>().toList()..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      await encoder.addFile(f, p.relative(f.path, from: dir).replaceAll(r'\', '/'));
    }
    await encoder.close();
  }

  /// Небольшое приложение: Info.plist (бинарный или XML), бинарник, иконка, расширение, метаданные App Store.
  static Future<String> ipa(
    Directory root, {
    int? cryptid = 0,
    bool binaryPlist = false,
    bool withExtension = true,
    bool withWatch = false,
    bool withStoreMetadata = true,
    Map<String, dynamic>? entitlements,
    String bundleID = 'com.example.demo',
  }) async {
    final src = p.join(root.path, 'src');
    final app = p.join(src, 'Payload', 'Demo.app');
    final info = {
      'CFBundleIdentifier': bundleID,
      'CFBundleExecutable': 'Demo',
      'CFBundleDisplayName': 'Демо',
      'CFBundleShortVersionString': '1.2.3',
      'CFBundleVersion': '45',
      'MinimumOSVersion': '15.0',
      'CFBundleIcons': {
        'CFBundlePrimaryIcon': {
          'CFBundleIconFiles': ['AppIcon60x60'],
        },
      },
    };
    await write(
      p.join(app, 'Info.plist'),
      binaryPlist ? File('test/fixtures/sample.bplist').readAsBytesSync() : utf8.encode(Plist.toXml(info)),
    );
    await write(p.join(app, 'Demo'), machO(cryptid: cryptid, entitlements: entitlements));
    await write(p.join(app, 'AppIcon60x60@2x.png'), cgbiPNG(2, 2, List.filled(16, 200)));
    await write(p.join(app, 'AppIcon60x60@3x.png'), cgbiPNG(3, 3, List.filled(36, 100)));
    if (withExtension) {
      final ext = p.join(app, 'PlugIns', 'Share.appex');
      await write(
        p.join(ext, 'Info.plist'),
        utf8.encode(Plist.toXml({'CFBundleIdentifier': '$bundleID.share', 'CFBundleExecutable': 'Share'})),
      );
      await write(p.join(ext, 'Share'), machO(cryptid: cryptid, entitlements: entitlements));
    }
    if (withWatch) await write(p.join(app, 'Watch', 'W.app', 'Info.plist'), utf8.encode(Plist.toXml({'CFBundleIdentifier': 'w'})));
    if (withStoreMetadata) {
      await write(
        p.join(src, 'iTunesMetadata.plist'),
        utf8.encode(
          Plist.toXml({
            'itemId': 123456789,
            'itemName': 'Демо',
            'artistName': 'Example LLC',
            'softwareVersionExternalIdentifier': 987,
            'com.apple.iTunesStore.downloadInfo': {
              'accountInfo': {'AppleID': 'me@example.com'},
              'purchaseDate': '2024-01-02T03:04:05Z',
            },
          }),
        ),
      );
    }
    final out = p.join(root.path, 'Demo.ipa');
    await zip(src, out);
    return out;
  }
}
