import 'package:flutter/material.dart';

import 'state/vault_store.dart';
import 'ui/app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(AppVaultApp(store: VaultStore()));
}
