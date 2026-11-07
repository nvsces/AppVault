import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';

/// Property list: XML и бинарный (bplist00) на чтение, XML на запись.
/// Типы: `Map<String, dynamic>`, `List`, `String`, `int`, `double`, `bool`, `DateTime` (UTC), `Uint8List`.
class Plist {
  static final _appleEpoch = DateTime.utc(2001, 1, 1);

  static dynamic parse(List<int> bytes) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    if (data.length >= 8 && ascii.decode(data.sublist(0, 6), allowInvalid: true) == 'bplist') {
      return _Binary(data).parse();
    }
    return _parseXml(utf8.decode(data, allowMalformed: true));
  }

  static Map<String, dynamic> parseDict(List<int> bytes) {
    final v = parse(bytes);
    if (v is Map<String, dynamic>) return v;
    throw const FormatException('plist: ожидался словарь');
  }

  // MARK: - XML

  static dynamic _parseXml(String text) {
    final doc = XmlDocument.parse(text.startsWith('﻿') ? text.substring(1) : text);
    final root = doc.rootElement;
    final first = root.name.local == 'plist' ? root.childElements.firstOrNull : root;
    if (first == null) throw const FormatException('plist: пустой документ');
    return _xmlValue(first);
  }

  static dynamic _xmlValue(XmlElement e) {
    switch (e.name.local) {
      case 'dict':
        final out = <String, dynamic>{};
        String? key;
        for (final child in e.childElements) {
          if (child.name.local == 'key') {
            key = child.innerText;
          } else if (key != null) {
            out[key] = _xmlValue(child);
            key = null;
          }
        }
        return out;
      case 'array':
        return e.childElements.map(_xmlValue).toList();
      case 'string':
        return e.innerText;
      case 'integer':
        return int.tryParse(e.innerText.trim()) ?? BigInt.parse(e.innerText.trim()).toInt();
      case 'real':
        return double.parse(e.innerText.trim());
      case 'true':
        return true;
      case 'false':
        return false;
      case 'date':
        return DateTime.parse(e.innerText.trim()).toUtc();
      case 'data':
        return base64.decode(e.innerText.replaceAll(RegExp(r'\s'), ''));
      default:
        throw FormatException('plist: неизвестный элемент <${e.name.local}>');
    }
  }

  static String toXml(dynamic value) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">')
      ..writeln('<plist version="1.0">');
    _write(b, value, 0);
    b.writeln('</plist>');
    return b.toString();
  }

  static Uint8List toXmlBytes(dynamic value) => Uint8List.fromList(utf8.encode(toXml(value)));

  static void _write(StringBuffer b, dynamic v, int depth) {
    final pad = '\t' * depth;
    if (v is Map) {
      if (v.isEmpty) {
        b.writeln('$pad<dict/>');
        return;
      }
      b.writeln('$pad<dict>');
      final keys = v.keys.map((k) => k.toString()).toList()..sort();
      for (final k in keys) {
        b.writeln('$pad\t<key>${_escape(k)}</key>');
        _write(b, v[k], depth + 1);
      }
      b.writeln('$pad</dict>');
    } else if (v is Uint8List) {
      b.writeln('$pad<data>${base64.encode(v)}</data>');
    } else if (v is List) {
      if (v.isEmpty) {
        b.writeln('$pad<array/>');
        return;
      }
      b.writeln('$pad<array>');
      for (final item in v) {
        _write(b, item, depth + 1);
      }
      b.writeln('$pad</array>');
    } else if (v is bool) {
      b.writeln(v ? '$pad<true/>' : '$pad<false/>');
    } else if (v is int) {
      b.writeln('$pad<integer>$v</integer>');
    } else if (v is double) {
      b.writeln('$pad<real>$v</real>');
    } else if (v is DateTime) {
      final s = v.toUtc().toIso8601String();
      b.writeln('$pad<date>${s.split('.').first.replaceAll('Z', '')}Z</date>');
    } else {
      b.writeln('$pad<string>${_escape(v.toString())}</string>');
    }
  }

  static String _escape(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
}

/// bplist00: объекты по таблице смещений, ссылки — индексы фиксированной ширины.
class _Binary {
  _Binary(this.d);
  final Uint8List d;
  late int _refSize;
  late List<int> _offsets;

  dynamic parse() {
    if (d.length < 40) throw const FormatException('bplist: слишком короткий');
    final t = d.length - 32;
    final offsetSize = d[t + 6];
    _refSize = d[t + 7];
    final count = _uint(t + 8, 8);
    final top = _uint(t + 16, 8);
    final tableOffset = _uint(t + 24, 8);
    _offsets = [for (var i = 0; i < count; i++) _uint(tableOffset + i * offsetSize, offsetSize)];
    return _object(top, 0);
  }

  int _uint(int at, int size) {
    var v = 0;
    for (var i = 0; i < size; i++) {
      v = (v << 8) | d[at + i];
    }
    return v;
  }

  /// Длина объекта: младший полубайт маркера, 0xF — следом идёт целое с настоящей длиной.
  (int, int) _length(int at) {
    final low = d[at] & 0x0F;
    if (low != 0x0F) return (low, at + 1);
    final size = 1 << (d[at + 1] & 0x0F);
    return (_uint(at + 2, size), at + 2 + size);
  }

  dynamic _object(int index, int depth) {
    if (depth > 512) throw const FormatException('bplist: слишком глубокая вложенность');
    final at = _offsets[index];
    final marker = d[at];
    switch (marker >> 4) {
      case 0x0:
        if (marker == 0x08) return false;
        if (marker == 0x09) return true;
        return null;
      case 0x1:
        final size = 1 << (marker & 0x0F);
        if (size == 8) return ByteData.sublistView(d, at + 1, at + 9).getInt64(0);
        if (size == 16) return ByteData.sublistView(d, at + 9, at + 17).getInt64(0);
        return _uint(at + 1, size);
      case 0x2:
        final size = 1 << (marker & 0x0F);
        final bd = ByteData.sublistView(d, at + 1, at + 1 + size);
        return size == 4 ? bd.getFloat32(0) : bd.getFloat64(0);
      case 0x3:
        final seconds = ByteData.sublistView(d, at + 1, at + 9).getFloat64(0);
        return Plist._appleEpoch.add(Duration(microseconds: (seconds * 1e6).round()));
      case 0x4:
        final (n, start) = _length(at);
        return Uint8List.fromList(d.sublist(start, start + n));
      case 0x5:
        final (n, start) = _length(at);
        return latin1.decode(d.sublist(start, start + n));
      case 0x6:
        final (n, start) = _length(at);
        final units = [for (var i = 0; i < n; i++) (d[start + i * 2] << 8) | d[start + i * 2 + 1]];
        return String.fromCharCodes(units);
      case 0x8:
        return _uint(at + 1, (marker & 0x0F) + 1);
      case 0xA:
        final (n, start) = _length(at);
        return [for (var i = 0; i < n; i++) _object(_uint(start + i * _refSize, _refSize), depth + 1)];
      case 0xD:
        final (n, start) = _length(at);
        final out = <String, dynamic>{};
        for (var i = 0; i < n; i++) {
          final key = _object(_uint(start + i * _refSize, _refSize), depth + 1);
          out[key.toString()] = _object(_uint(start + (n + i) * _refSize, _refSize), depth + 1);
        }
        return out;
      default:
        throw FormatException('bplist: неизвестный маркер 0x${marker.toRadixString(16)}');
    }
  }
}

/// Удобные геттеры над словарём из plist.
extension PlistDict on Map<String, dynamic> {
  String? str(String key) => this[key] is String ? this[key] as String : null;
  bool? flag(String key) => this[key] is bool ? this[key] as bool : null;
  Map<String, dynamic>? dict(String key) => this[key] is Map<String, dynamic> ? this[key] as Map<String, dynamic> : null;
  List<dynamic>? list(String key) => this[key] is List ? this[key] as List : null;

  int? integer(String key) {
    final v = this[key];
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    if (v is double) return v.toInt();
    return null;
  }
}
