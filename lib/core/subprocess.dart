import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Отмена фоновой операции: запущенные процессы завершаются, ожидание прерывается.
class CancelToken {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void Function() onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void check() {
    if (_cancelled) throw const CancelledException();
  }
}

class CancelledException implements Exception {
  const CancelledException();
  @override
  String toString() => 'Отменено';
}

class SubprocessResult {
  SubprocessResult(this.status, this.stdout, this.stderr);
  final int status;
  final Uint8List stdout;
  final Uint8List stderr;

  String get out => utf8.decode(stdout, allowMalformed: true);
  String get err => utf8.decode(stderr, allowMalformed: true);
}

class SubprocessException implements Exception {
  SubprocessException(this.message);
  final String message;
  @override
  String toString() => message;

  /// Строка с причиной ошибки. Утилиты libimobiledevice пишут её последней
  /// или помечают префиксом `ERROR`, а перед ней — ход выполнения.
  static String summary(String text) {
    final lines = text.split(RegExp(r'[\r\n]+')).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    return lines.lastWhere((l) => l.startsWith('ERROR'), orElse: () => lines.isEmpty ? '' : lines.last);
  }
}

typedef LineHandler = void Function(String line);

class Subprocess {
  /// Запуск с таймаутом и отменой. Строки делятся и по `\n`, и по `\r` —
  /// ideviceinstaller рисует прогресс через возврат каретки.
  static Future<SubprocessResult> run(
    String executable,
    List<String> args, {
    String? cwd,
    Map<String, String>? env,
    Duration timeout = const Duration(minutes: 2),
    CancelToken? cancel,
    LineHandler? onStdout,
    LineHandler? onStderr,
  }) async {
    cancel?.check();
    final name = executable.split(RegExp(r'[\\/]')).last;
    final Process proc;
    try {
      proc = await Process.start(executable, args, workingDirectory: cwd, environment: env);
    } on ProcessException catch (e) {
      throw SubprocessException('$name не запускается: ${e.message}');
    }
    final out = BytesBuilder(copy: false), err = BytesBuilder(copy: false);
    final outDone = _collect(proc.stdout, out, onStdout);
    final errDone = _collect(proc.stderr, err, onStderr);
    unawaited(proc.stdin.close().catchError((_) {}));

    var timedOut = false;
    final timer = Timer(timeout, () {
      timedOut = true;
      proc.kill();
    });
    final unsubscribe = cancel?.onCancel(() => proc.kill());
    try {
      final status = await proc.exitCode;
      await Future.wait([outDone, errDone]);
      if (cancel?.isCancelled ?? false) throw const CancelledException();
      if (timedOut) throw SubprocessException('$name: превышено время ожидания');
      return SubprocessResult(status, out.takeBytes(), err.takeBytes());
    } finally {
      timer.cancel();
      unsubscribe?.call();
    }
  }

  /// То же, но ненулевой код завершения — ошибка с понятной строкой из вывода.
  static Future<SubprocessResult> check(
    String executable,
    List<String> args, {
    String? cwd,
    Map<String, String>? env,
    Duration timeout = const Duration(minutes: 2),
    CancelToken? cancel,
    LineHandler? onStdout,
    LineHandler? onStderr,
  }) async {
    final r = await run(executable, args, cwd: cwd, env: env, timeout: timeout, cancel: cancel, onStdout: onStdout, onStderr: onStderr);
    if (r.status != 0) {
      final name = executable.split(RegExp(r'[\\/]')).last;
      final line = SubprocessException.summary(r.err.trim().isEmpty ? r.out : r.err);
      throw SubprocessException('$name завершился с кодом ${r.status}${line.isEmpty ? '' : ': $line'}');
    }
    return r;
  }

  static Future<void> _collect(Stream<List<int>> stream, BytesBuilder sink, LineHandler? onLine) async {
    if (onLine == null) {
      await for (final chunk in stream) {
        sink.add(chunk);
      }
      return;
    }
    var pending = '';
    // A UTF-8 character can span pipe chunks (notably Cyrillic names on Windows).
    final decoded = stream
        .map((chunk) {
          sink.add(chunk);
          return chunk;
        })
        .transform(const Utf8Decoder(allowMalformed: true));
    await for (final chunk in decoded) {
      pending += chunk;
      final parts = pending.split(RegExp(r'[\r\n]'));
      pending = parts.removeLast();
      for (final line in parts) {
        if (line.trim().isNotEmpty) onLine(line.trim());
      }
    }
    if (pending.trim().isNotEmpty) onLine(pending.trim());
  }
}
