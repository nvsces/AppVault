import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'ipa.dart';
import 'paths.dart';

sealed class LibrarySource {
  const LibrarySource();

  String get title;
  Map<String, dynamic> toJson();

  static LibrarySource fromJson(Map<String, dynamic> j) => switch (j['type']) {
    'appStore' => AppStoreSource(j['appID'] as int, j['versionID'] as String?),
    'cache' => CacheSource(j['location'] as String),
    'resigned' => ResignedSource(j['from'] as String?, j['teamID'] as String),
    _ => ImportedSource(j['path'] as String? ?? ''),
  };
}

class ImportedSource extends LibrarySource {
  const ImportedSource(this.path);
  final String path;
  @override
  String get title => 'Импорт';
  @override
  Map<String, dynamic> toJson() => {'type': 'imported', 'path': path};
}

class AppStoreSource extends LibrarySource {
  const AppStoreSource(this.appID, this.versionID);
  final int appID;
  final String? versionID;
  @override
  String get title => 'App Store';
  @override
  Map<String, dynamic> toJson() => {'type': 'appStore', 'appID': appID, 'versionID': versionID};
}

class CacheSource extends LibrarySource {
  const CacheSource(this.location);
  final String location;
  @override
  String get title => location;
  @override
  Map<String, dynamic> toJson() => {'type': 'cache', 'location': location};
}

class ResignedSource extends LibrarySource {
  const ResignedSource(this.from, this.teamID);
  final String? from;
  final String teamID;
  @override
  String get title => 'Переподписано · $teamID';
  @override
  Map<String, dynamic> toJson() => {'type': 'resigned', 'from': from, 'teamID': teamID};
}

class LibraryItem {
  const LibraryItem({required this.id, required this.fileName, required this.info, required this.addedAt, required this.source});

  final String id;
  final String fileName;
  final IPAInfo info;
  final DateTime addedAt;
  final LibrarySource source;

  bool get isResigned => source is ResignedSource;

  /// До какого числа действует подпись своим сертификатом.
  DateTime? get signedUntil => isResigned ? info.embeddedProfile?.expiration : null;

  factory LibraryItem.fromJson(Map<String, dynamic> j) => LibraryItem(
    id: j['id'] as String,
    fileName: j['fileName'] as String,
    info: IPAInfo.fromJson(j['info'] as Map<String, dynamic>),
    addedAt: DateTime.parse(j['addedAt'] as String),
    source: LibrarySource.fromJson(j['source'] as Map<String, dynamic>),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'fileName': fileName,
    'info': info.toJson(),
    'addedAt': addedAt.toUtc().toIso8601String(),
    'source': source.toJson(),
  };
}

/// Хранилище IPA: `<данные>\Library\<id>\` с файлом, иконкой и общим index.json.
class LibraryStorage {
  LibraryStorage(this.root) {
    Directory(root).createSync(recursive: true);
  }

  final String root;

  String get _indexPath => p.join(root, 'index.json');
  String folder(String id) => p.join(root, id);
  String ipaPath(LibraryItem item) => p.join(folder(item.id), item.fileName);
  String iconPath(LibraryItem item) => p.join(folder(item.id), 'icon.png');

  List<LibraryItem> load() {
    final f = File(_indexPath);
    if (!f.existsSync()) return [];
    try {
      final list = jsonDecode(f.readAsStringSync()) as List;
      // Файл могли удалить руками — такие записи не показываем.
      return list.map((e) => LibraryItem.fromJson(e as Map<String, dynamic>)).where((i) => File(ipaPath(i)).existsSync()).toList();
    } catch (_) {
      return [];
    }
  }

  void save(List<LibraryItem> items) {
    final tmp = File('$_indexPath.tmp');
    tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(items.map((i) => i.toJson()).toList()));
    tmp.renameSync(_indexPath);
  }

  /// Разбирает IPA и кладёт копию в библиотеку. `move` — забрать файл (временные загрузки).
  Future<LibraryItem> add(String path, LibrarySource source, {bool move = false}) async {
    final inspected = await IPAInspector.inspect(path);
    final id = newUUID();
    final dir = Directory(folder(id));
    await dir.create(recursive: true);
    final fileName = fileNameFor(inspected.info);
    final dest = p.join(dir.path, fileName);
    try {
      if (move) {
        await _move(File(path), dest);
      } else {
        await File(path).copy(dest);
      }
    } catch (_) {
      await dir.delete(recursive: true);
      rethrow;
    }
    if (inspected.icon != null) await File(p.join(dir.path, 'icon.png')).writeAsBytes(inspected.icon!);
    return LibraryItem(id: id, fileName: fileName, info: inspected.info, addedAt: DateTime.now(), source: source);
  }

  /// Переименование не работает между дисками — тогда копируем и удаляем.
  static Future<void> _move(File f, String dest) async {
    try {
      await f.rename(dest);
    } on FileSystemException {
      await f.copy(dest);
      await f.delete();
    }
  }

  Future<void> remove(LibraryItem item) async {
    final dir = Directory(folder(item.id));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// Windows запрещает в именах `<>:"/\|?*` и точку или пробел в конце.
  static String fileNameFor(IPAInfo info) {
    final base = '${info.name} ${info.version}'.trim();
    var safe = base.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '-');
    if (safe.length > 100) safe = safe.substring(0, 100);
    safe = safe.replaceAll(RegExp(r'[. ]+$'), '');
    return '${safe.isEmpty ? 'app' : safe}.ipa';
  }
}

/// IPA, которые уже лежат на диске: медиатека iTunes, iMazing, 3uTools, загрузки.
class FoundIPA {
  const FoundIPA(this.path, this.location, this.size, this.modified);
  final String path;
  final String location;
  final int size;
  final DateTime modified;
}

class ScanLocation {
  const ScanLocation(this.title, this.path, this.depth);
  final String title;
  final String path;
  final int depth;
}

class CacheScanner {
  static List<ScanLocation> locations(List<String> extra) {
    final home = AppPaths.home;
    final env = Platform.environment;
    final appData = env['APPDATA'] ?? p.join(home, 'AppData', 'Roaming');
    final list = [
      ScanLocation('iTunes', p.join(home, 'Music', 'iTunes', 'iTunes Media', 'Mobile Applications'), 2),
      ScanLocation('iTunes (старый)', p.join(home, 'Music', 'iTunes', 'Mobile Applications'), 2),
      ScanLocation('iMazing', p.join(appData, 'iMazing'), 6),
      ScanLocation('3uTools', p.join(home, '3uTools'), 5),
      ScanLocation('Загрузки', p.join(home, 'Downloads'), 3),
      ScanLocation('Рабочий стол', p.join(home, 'Desktop'), 2),
      for (final path in extra.where((e) => e.trim().isNotEmpty)) ScanLocation(p.basename(path.trim()), path.trim(), 6),
    ];
    return list;
  }

  static Future<List<FoundIPA>> scan(List<ScanLocation> locations) async {
    final found = <FoundIPA>[];
    for (final loc in locations) {
      final dir = Directory(loc.path);
      if (!await dir.exists()) continue;
      await _walk(dir, loc, 0, found);
    }
    found.sort((a, b) => b.modified.compareTo(a.modified));
    return found;
  }

  static Future<void> _walk(Directory dir, ScanLocation loc, int level, List<FoundIPA> out) async {
    if (level > loc.depth) return;
    try {
      await for (final e in dir.list(followLinks: false)) {
        final name = p.basename(e.path);
        if (name.startsWith('.')) continue;
        if (e is Directory) {
          await _walk(e, loc, level + 1, out);
        } else if (e is File && name.toLowerCase().endsWith('.ipa')) {
          final stat = await e.stat();
          out.add(FoundIPA(e.path, loc.title, stat.size, stat.modified));
        }
      }
    } on FileSystemException {
      return; // нет доступа — пропускаем папку
    }
  }
}
