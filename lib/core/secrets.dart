import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Секреты (пароль к .p12, ключ App Store Connect, пароль к хранилищу ipatool) — в файлах,
/// зашифрованных DPAPI: расшифровать их может только эта учётная запись Windows.
/// На других системах (разработка) — открытым текстом, с предупреждением в имени файла.
class SecretStore {
  SecretStore(this.directory);
  final String directory;

  String _file(String name) => p.join(directory, Platform.isWindows ? '$name.dpapi' : '$name.insecure');

  String? get(String name) {
    final f = File(_file(name));
    if (!f.existsSync()) return null;
    try {
      final data = f.readAsBytesSync();
      return utf8.decode(Platform.isWindows ? _Dpapi.unprotect(data) : data);
    } catch (_) {
      return null;
    }
  }

  void set(String name, String value) {
    Directory(directory).createSync(recursive: true);
    final data = Uint8List.fromList(utf8.encode(value));
    File(_file(name)).writeAsBytesSync(Platform.isWindows ? _Dpapi.protect(data) : data, flush: true);
  }

  void delete(String name) {
    final f = File(_file(name));
    if (f.existsSync()) f.deleteSync();
  }
}

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative =
    Int32 Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _CryptDart =
    int Function(Pointer<_DataBlob>, Pointer<Utf16>, Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _UnprotectNative =
    Int32 Function(
      Pointer<_DataBlob>,
      Pointer<Pointer<Utf16>>,
      Pointer<_DataBlob>,
      Pointer<Void>,
      Pointer<Void>,
      Uint32,
      Pointer<_DataBlob>,
    );
typedef _UnprotectDart =
    int Function(Pointer<_DataBlob>, Pointer<Pointer<Utf16>>, Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void>);
typedef _LocalFreeDart = Pointer<Void> Function(Pointer<Void>);

/// CryptProtectData / CryptUnprotectData из crypt32.dll.
class _Dpapi {
  static const _uiForbidden = 0x1;
  static final _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _protect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData');
  static final _unprotect = _crypt32.lookupFunction<_UnprotectNative, _UnprotectDart>('CryptUnprotectData');
  static final _localFree = _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

  static Uint8List protect(Uint8List data) => _call(data, protect: true);
  static Uint8List unprotect(Uint8List data) => _call(data, protect: false);

  static Uint8List _call(Uint8List data, {required bool protect}) {
    final input = calloc<_DataBlob>();
    final output = calloc<_DataBlob>();
    final buffer = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      buffer.asTypedList(data.length).setAll(0, data);
      input.ref
        ..cbData = data.length
        ..pbData = buffer;
      final ok = protect
          ? _protect(input, nullptr, nullptr, nullptr, nullptr, _uiForbidden, output)
          : _unprotect(input, nullptr, nullptr, nullptr, nullptr, _uiForbidden, output);
      if (ok == 0) throw const FileSystemException('DPAPI: не удалось обработать секрет');
      final result = Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
      _localFree(output.ref.pbData.cast());
      return result;
    } finally {
      calloc.free(buffer);
      calloc.free(input);
      calloc.free(output);
    }
  }
}
