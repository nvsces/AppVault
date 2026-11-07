// A native test executable so the resign pipeline also runs on Windows.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  if (args.firstOrNull == '--emit-split-utf8') {
    final bytes = utf8.encode('Передача приложения\rГотово\n');
    stdout.add(bytes.sublist(0, 1));
    await stdout.flush();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    stdout.add(bytes.sublist(1));
    return;
  }
  final output = p.dirname(Platform.resolvedExecutable);
  File(p.join(output, 'args.txt')).writeAsStringSync('${args.join('\n')}\n');
  for (final file in Directory.current.listSync().whereType<File>()) {
    final name = p.basename(file.path);
    if (name.startsWith('entitlements-') && name.endsWith('.plist')) {
      file.copySync(p.join(output, name));
    }
  }
}
