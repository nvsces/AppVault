import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/tools.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final _extra = TextEditingController(text: StoreScope.read(context).settings.extraScanFolders);

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader('Настройки'),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(Gap.page),
            children: [
              SectionCard(
                title: 'Утилиты',
                icon: Icons.build_outlined,
                children: [
                  const Muted(
                    'AppVault ищет утилиты в папке из настройки ниже, в папке tools рядом с AppVault.exe, '
                    'в папке данных и в PATH. В установщик входит полный комплект; для сборки из исходников '
                    'их скачивает scripts\\fetch_tools.ps1.',
                  ),
                  for (final t in Tool.values)
                    Row(
                      children: [
                        SizedBox(
                          width: 220,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [Text(t.fileName), Muted(t.purpose, small: true)],
                          ),
                        ),
                        Expanded(
                          child: Toolbox.path(t) != null
                              ? SelectableText(Toolbox.path(t)!, style: const TextStyle(fontFamily: 'Consolas', fontSize: 12))
                              : const Text('не найден', style: TextStyle(color: Colors.orange)),
                        ),
                      ],
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: KeyValue('Своя папка', store.settings.toolsDir.isEmpty ? '—' : store.settings.toolsDir, keyWidth: 110),
                      ),
                      OutlinedButton(
                        onPressed: () async {
                          final dir = await getDirectoryPath(confirmButtonText: 'Выбрать');
                          if (dir != null) store.setToolsDir(dir);
                        },
                        child: const Text('Выбрать папку…'),
                      ),
                      if (store.settings.toolsDir.isNotEmpty)
                        TextButton(onPressed: () => store.setToolsDir(''), child: const Text('Сбросить')),
                      const SizedBox(width: 8),
                      TextButton(onPressed: store.refreshTools, child: const Text('Проверить снова')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: Gap.pad),
              SectionCard(
                title: 'Данные',
                icon: Icons.folder_outlined,
                children: [
                  Row(
                    children: [
                      Expanded(child: KeyValue('Папка', store.paths.root, keyWidth: 110, mono: true)),
                      OutlinedButton(onPressed: () => store.openFolder(store.paths.root), child: const Text('Открыть')),
                    ],
                  ),
                  const Muted(
                    'Library — IPA и index.json, Profiles — профили, Identities — сертификаты .p12, Secrets — пароли под DPAPI.',
                    small: true,
                  ),
                ],
              ),
              const SizedBox(height: Gap.pad),
              SectionCard(
                title: 'Дополнительные папки для поиска IPA',
                icon: Icons.travel_explore,
                children: [
                  TextField(
                    controller: _extra,
                    maxLines: 4,
                    style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
                    decoration: const InputDecoration(border: OutlineInputBorder(), hintText: r'D:\Архив\IPA'),
                    onChanged: (v) {
                      store.settings.extraScanFolders = v;
                      store.saveSettings();
                    },
                  ),
                  const Muted('По одному пути на строку — например, внешний диск с архивом приложений.', small: true),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
