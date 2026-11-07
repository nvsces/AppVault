import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'macho.dart';
import 'plist.dart';
import 'png.dart';
import 'provisioning.dart';
import 'zip.dart';

enum EncryptionState { encrypted, decrypted, unknown }

/// Сведения из iTunesMetadata.plist: его кладёт App Store (и ipatool) рядом с Payload.
class StoreMetadata {
  const StoreMetadata({
    this.itemID,
    this.itemName,
    this.artistName,
    this.purchaserAppleID,
    this.purchaseDate,
    this.externalVersionID,
    this.genre,
  });

  final int? itemID;
  final String? itemName;
  final String? artistName;
  final String? purchaserAppleID;
  final DateTime? purchaseDate;
  final int? externalVersionID;
  final String? genre;

  factory StoreMetadata.fromPlist(Map<String, dynamic> d) {
    final download = d.dict('com.apple.iTunesStore.downloadInfo');
    final account = download?.dict('accountInfo');
    return StoreMetadata(
      itemID: d.integer('itemId'),
      itemName: d.str('itemName'),
      artistName: d.str('artistName') ?? d.str('playlistArtistName'),
      purchaserAppleID: account?.str('AppleID') ?? d.str('apple-id') ?? d.str('appleId') ?? d.str('userName'),
      purchaseDate: parseDate(download?['purchaseDate']) ?? parseDate(d['purchaseDate']),
      externalVersionID: d.integer('softwareVersionExternalIdentifier'),
      genre: d.str('genre'),
    );
  }

  factory StoreMetadata.fromJson(Map<String, dynamic> j) => StoreMetadata(
    itemID: j['itemID'] as int?,
    itemName: j['itemName'] as String?,
    artistName: j['artistName'] as String?,
    purchaserAppleID: j['purchaserAppleID'] as String?,
    purchaseDate: parseDate(j['purchaseDate']),
    externalVersionID: j['externalVersionID'] as int?,
    genre: j['genre'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'itemID': itemID,
    'itemName': itemName,
    'artistName': artistName,
    'purchaserAppleID': purchaserAppleID,
    'purchaseDate': purchaseDate?.toUtc().toIso8601String(),
    'externalVersionID': externalVersionID,
    'genre': genre,
  };
}

DateTime? parseDate(dynamic v) {
  if (v is DateTime) return v;
  if (v is String) return DateTime.tryParse(v);
  return null;
}

/// Встроенный в приложение профиль — чем и до какого числа оно подписано.
class EmbeddedProfileInfo {
  const EmbeddedProfileInfo({
    required this.name,
    required this.teamID,
    required this.teamName,
    required this.expiration,
    required this.deviceCount,
    required this.provisionsAllDevices,
  });

  final String name;
  final String teamID;
  final String teamName;
  final DateTime expiration;
  final int deviceCount;
  final bool provisionsAllDevices;

  factory EmbeddedProfileInfo.fromJson(Map<String, dynamic> j) => EmbeddedProfileInfo(
    name: j['name'] as String,
    teamID: j['teamID'] as String,
    teamName: j['teamName'] as String,
    expiration: DateTime.parse(j['expiration'] as String),
    deviceCount: j['deviceCount'] as int,
    provisionsAllDevices: j['provisionsAllDevices'] as bool,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'teamID': teamID,
    'teamName': teamName,
    'expiration': expiration.toUtc().toIso8601String(),
    'deviceCount': deviceCount,
    'provisionsAllDevices': provisionsAllDevices,
  };
}

enum IPAKind {
  /// Зашифрованный бинарник App Store: ставится как есть на устройство с купившим Apple ID.
  appStore,

  /// Незашифрованный: можно переподписать своим сертификатом.
  resignable,
}

class IPAInfo {
  const IPAInfo({
    required this.bundleID,
    required this.name,
    required this.version,
    required this.build,
    this.minimumOS,
    required this.executable,
    required this.appPath,
    required this.encryption,
    required this.architectures,
    required this.hasSinf,
    this.store,
    required this.extensions,
    required this.hasWatchApp,
    this.embeddedProfile,
    required this.fileSize,
  });

  final String bundleID;
  final String name;
  final String version;
  final String build;
  final String? minimumOS;
  final String executable;

  /// Путь к бандлу внутри архива: `Payload/Name.app`.
  final String appPath;
  final EncryptionState encryption;
  final List<String> architectures;
  final bool hasSinf;
  final StoreMetadata? store;

  /// Расширения относительно бандла: `PlugIns/Share.appex`.
  final List<String> extensions;
  final bool hasWatchApp;
  final EmbeddedProfileInfo? embeddedProfile;
  final int fileSize;

  IPAKind get kind => switch (encryption) {
    EncryptionState.encrypted => IPAKind.appStore,
    EncryptionState.decrypted => IPAKind.resignable,
    EncryptionState.unknown => hasSinf ? IPAKind.appStore : IPAKind.resignable,
  };

  factory IPAInfo.fromJson(Map<String, dynamic> j) => IPAInfo(
    bundleID: j['bundleID'] as String,
    name: j['name'] as String,
    version: j['version'] as String,
    build: j['build'] as String,
    minimumOS: j['minimumOS'] as String?,
    executable: j['executable'] as String,
    appPath: j['appPath'] as String,
    encryption: EncryptionState.values.byName(j['encryption'] as String),
    architectures: (j['architectures'] as List).cast<String>(),
    hasSinf: j['hasSinf'] as bool,
    store: j['store'] == null ? null : StoreMetadata.fromJson(j['store'] as Map<String, dynamic>),
    extensions: (j['extensions'] as List).cast<String>(),
    hasWatchApp: j['hasWatchApp'] as bool,
    embeddedProfile: j['embeddedProfile'] == null ? null : EmbeddedProfileInfo.fromJson(j['embeddedProfile'] as Map<String, dynamic>),
    fileSize: j['fileSize'] as int,
  );

  Map<String, dynamic> toJson() => {
    'bundleID': bundleID,
    'name': name,
    'version': version,
    'build': build,
    'minimumOS': minimumOS,
    'executable': executable,
    'appPath': appPath,
    'encryption': encryption.name,
    'architectures': architectures,
    'hasSinf': hasSinf,
    'store': store?.toJson(),
    'extensions': extensions,
    'hasWatchApp': hasWatchApp,
    'embeddedProfile': embeddedProfile?.toJson(),
    'fileSize': fileSize,
  };
}

class IPAException implements Exception {
  IPAException(this.message);
  final String message;
  @override
  String toString() => message;
}

class InspectedIPA {
  const InspectedIPA(this.info, this.icon);
  final IPAInfo info;

  /// Иконка, перекодированная в обычный PNG.
  final Uint8List? icon;
}

class IPAInspector {
  static final _infoPlist = RegExp(r'^Payload/[^/]+\.app/Info\.plist$');

  static Future<InspectedIPA> inspect(String path) async {
    final ZipReader zip;
    try {
      zip = await ZipReader.open(path);
    } on ZipException {
      throw IPAException('${p.basename(path)} — не IPA: это не zip-архив');
    }
    final infoPath = zip.names.where(_infoPlist.hasMatch).firstOrNull;
    if (infoPath == null) throw IPAException('${p.basename(path)} — не IPA: внутри нет Payload/*.app');
    final appPath = infoPath.substring(0, infoPath.length - '/Info.plist'.length);
    final Map<String, dynamic> plist;
    try {
      plist = Plist.parseDict(await zip.read(infoPath));
    } on FormatException {
      throw IPAException('${p.basename(path)}: не читается Info.plist приложения');
    }

    final appName = p.basenameWithoutExtension(appPath);
    final executable = plist.str('CFBundleExecutable') ?? appName;
    var encryption = EncryptionState.unknown;
    var archs = <String>[];
    final probe = await _probeBinary(zip, '$appPath/$executable');
    if (probe case MachOSlices(slices: final slices)) {
      archs = slices.map((s) => s.cpu).toList();
      encryption = probe.isEncrypted ? EncryptionState.encrypted : EncryptionState.decrypted;
    }

    StoreMetadata? store;
    if (zip['iTunesMetadata.plist'] != null) {
      try {
        store = StoreMetadata.fromPlist(Plist.parseDict(await zip.read('iTunesMetadata.plist')));
      } on FormatException {
        store = null;
      }
    }

    EmbeddedProfileInfo? embedded;
    final profileEntry = '$appPath/embedded.mobileprovision';
    if (zip[profileEntry] != null) {
      try {
        final pr = ProvisioningProfile.decode(await zip.read(profileEntry));
        embedded = EmbeddedProfileInfo(
          name: pr.name,
          teamID: pr.teamID,
          teamName: pr.teamName,
          expiration: pr.expiration,
          deviceCount: pr.devices.length,
          provisionsAllDevices: pr.provisionsAllDevices,
        );
      } on ProfileException {
        embedded = null;
      }
    }

    final extPattern = RegExp('^${RegExp.escape(appPath)}/(PlugIns|Extensions)/[^/]+\\.appex/Info\\.plist\$');
    final extensions = zip.names
        .where(extPattern.hasMatch)
        .map((e) => e.substring(appPath.length + 1, e.length - '/Info.plist'.length))
        .toList();

    final display = plist.str('CFBundleDisplayName');
    final name = (display != null && display.isNotEmpty ? display : null) ?? plist.str('CFBundleName') ?? store?.itemName ?? appName;

    final info = IPAInfo(
      bundleID: plist.str('CFBundleIdentifier') ?? '',
      name: name,
      version: plist.str('CFBundleShortVersionString') ?? '',
      build: plist.str('CFBundleVersion') ?? '',
      minimumOS: plist.str('MinimumOSVersion'),
      executable: executable,
      appPath: appPath,
      encryption: encryption,
      architectures: archs,
      hasSinf: zip.names.any((e) => e.startsWith('$appPath/SC_Info/') && e.endsWith('.sinf')),
      store: store,
      extensions: extensions,
      hasWatchApp: zip.names.any((e) => e.startsWith('$appPath/Watch/')),
      embeddedProfile: embedded,
      fileSize: await File(path).length(),
    );

    Uint8List? icon;
    final iconPath = iconEntry(zip.names.toList(), appPath, plist);
    if (iconPath != null) {
      try {
        icon = PngDecoder.normalize(await zip.read(iconPath));
      } catch (_) {
        icon = null;
      }
    }
    return InspectedIPA(info, icon);
  }

  /// Бинарник читается из архива ровно настолько, насколько нужно для разбора заголовка.
  static Future<MachOProbe> _probeBinary(ZipReader zip, String entry) async {
    if (zip[entry] == null) return const MachONotMachO();
    var threshold = 0;
    final data = await zip.readPrefix(entry, (d) {
      if (d.length < threshold) return false;
      final r = MachO.probe(d);
      if (r is MachONeedMore) {
        threshold = r.bytes;
        return false;
      }
      return true;
    });
    final r = MachO.probe(data);
    return r is MachONeedMore ? const MachONotMachO() : r;
  }

  /// Самая крупная иконка из перечисленных в Info.plist; запасной вариант — iTunesArtwork в корне архива.
  static String? iconEntry(List<String> entries, String appPath, Map<String, dynamic> plist) {
    final names = <String>[];
    for (final key in ['CFBundleIcons', 'CFBundleIcons~ipad']) {
      final primary = plist.dict(key)?.dict('CFBundlePrimaryIcon');
      if (primary != null) {
        names.addAll(primary.list('CFBundleIconFiles')?.whereType<String>() ?? const []);
        final n = primary.str('CFBundleIconName');
        if (n != null) names.add(n);
      }
    }
    names.addAll(plist.list('CFBundleIconFiles')?.whereType<String>() ?? const []);
    final single = plist.str('CFBundleIconFile');
    if (single != null) names.add(single);
    if (names.isEmpty) names.addAll(['AppIcon', 'Icon']);

    final prefix = '$appPath/';
    final candidates = entries.where((e) {
      if (!e.startsWith(prefix) || !e.toLowerCase().endsWith('.png')) return false;
      final file = e.substring(prefix.length);
      return !file.contains('/') && names.any(file.startsWith);
    }).toList();
    if (candidates.isNotEmpty) {
      return candidates.reduce((a, b) => iconScore(a) >= iconScore(b) ? a : b);
    }
    return entries.where((e) => e == 'iTunesArtwork' || e == 'iTunesArtwork@2x').firstOrNull;
  }

  /// Размер в точках × масштаб: AppIcon60x60@3x → 180, AppIcon83.5x83.5@2x~ipad → 167.
  static double iconScore(String path) {
    final name = p.posix.basename(path);
    final scale = name.contains('@3x') ? 3.0 : (name.contains('@2x') ? 2.0 : 1.0);
    final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(name);
    return (m != null ? double.parse(m.group(1)!) : 20) * scale;
  }
}
