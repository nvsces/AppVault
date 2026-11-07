import 'package:flutter/foundation.dart';

import '../core/paths.dart';
import '../core/subprocess.dart';

enum JobState { running, succeeded, cancelled, failed }

/// Фоновая операция с журналом: импорт, скачивание, переподпись, установка.
class Job extends ChangeNotifier {
  Job(this.title);

  final String id = newUUID();
  final String title;
  final DateTime started = DateTime.now();
  final CancelToken token = CancelToken();
  JobState state = JobState.running;
  String? error;
  double? progress;
  String status = '';
  final List<String> log = [];

  bool get isRunning => state == JobState.running;

  void append(String line) {
    status = line;
    log.add(line);
    if (log.length > 2000) log.removeRange(0, log.length - 2000);
    notifyListeners();
  }

  void setProgress(double? value, [String? statusLine]) {
    progress = value;
    if (statusLine != null) status = statusLine;
    notifyListeners();
  }

  void finish(JobState result, [String? message]) {
    state = result;
    error = message;
    if (result == JobState.succeeded) progress = 1;
    notifyListeners();
  }

  void cancel() => token.cancel();
}
