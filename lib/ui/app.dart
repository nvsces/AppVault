import 'package:flutter/material.dart';

import '../state/job.dart';
import '../state/vault_store.dart';
import 'devices_page.dart';
import 'jobs_page.dart';
import 'library_page.dart';
import 'settings_page.dart';
import 'signing_page.dart';
import 'store_page.dart';
import 'widgets.dart';

class AppVaultApp extends StatelessWidget {
  const AppVaultApp({super.key, required this.store});
  final VaultStore store;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB), brightness: b),
      fontFamily: 'Segoe UI',
      visualDensity: VisualDensity.compact,
      useMaterial3: true,
    );
    return StoreScope(
      store: store,
      child: MaterialApp(
        title: 'AppVault',
        debugShowCheckedModeBanner: false,
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        home: const Shell(),
      ),
    );
  }
}

enum Section {
  library('Библиотека', Icons.inventory_2_outlined),
  store('App Store', Icons.shopping_bag_outlined),
  devices('Устройства', Icons.phone_iphone),
  signing('Подпись', Icons.draw_outlined),
  jobs('Задачи', Icons.list_alt),
  settings('Настройки', Icons.settings_outlined);

  const Section(this.title, this.icon);
  final String title;
  final IconData icon;
}

class Shell extends StatelessWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final section = Section.values.asNameMap()[store.settings.section] ?? Section.library;
    final running = store.jobs.where((j) => j.isRunning).firstOrNull;
    void open(Section s) {
      store.settings.section = s.name;
      store.saveSettings();
    }

    return Scaffold(
      body: Row(
        children: [
          Sidebar(selected: section, onSelect: open),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: switch (section) {
                    Section.library => const LibraryPage(),
                    Section.store => const StorePage(),
                    Section.devices => const DevicesPage(),
                    Section.signing => const SigningPage(),
                    Section.jobs => const JobsPage(),
                    Section.settings => const SettingsPage(),
                  },
                ),
                if (running != null) JobStrip(job: running, more: store.runningJobs - 1, onOpen: () => open(Section.jobs)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class Sidebar extends StatelessWidget {
  const Sidebar({super.key, required this.selected, required this.onSelect});
  final Section selected;
  final void Function(Section) onSelect;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    int? badge(Section s) => switch (s) {
      Section.library => store.items.length,
      Section.devices => store.devices.length,
      Section.jobs => store.runningJobs,
      _ => null,
    };
    return Container(
      width: 220,
      color: scheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
            child: Row(
              children: [
                Icon(Icons.inventory_2, color: scheme.primary),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'AppVault',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
          for (final s in Section.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              child: ListTile(
                dense: true,
                selected: s == selected,
                selectedTileColor: scheme.primary.withValues(alpha: 0.12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                leading: Icon(s.icon, size: 20),
                title: Text(s.title),
                trailing: (badge(s) ?? 0) > 0 ? CountBadge(badge(s)!) : null,
                onTap: () => onSelect(s),
              ),
            ),
          const Spacer(),
          const DevicePicker(),
          if (store.missingTools.isNotEmpty)
            Container(
              margin: const EdgeInsets.all(10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.orange.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Не хватает утилит',
                          style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Muted(store.missingTools.map((t) => t.command).join(', '), small: true),
                  TextButton(onPressed: () => onSelect(Section.settings), child: const Text('Настроить')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Устройство, на которое ставим, — всегда под рукой внизу боковой панели.
class DevicePicker extends StatelessWidget {
  const DevicePicker({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final d = store.selectedDevice;
    return PopupMenuButton<String>(
      tooltip: 'Устройство для установки',
      onSelected: (udid) => udid.isEmpty ? store.refreshDevices() : store.selectDevice(udid),
      itemBuilder: (_) => [
        if (store.devices.isEmpty) const PopupMenuItem(enabled: false, child: Text('Нет подключённых устройств')),
        for (final dev in store.devices)
          CheckedPopupMenuItem(
            value: dev.udid,
            checked: dev.udid == d?.udid,
            child: Text('${dev.name} — iOS ${dev.productVersion}, ${dev.connectionTitle}'),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: '', child: Text('Обновить список')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: [
            Icon(d == null ? Icons.phonelink_off : (d.useNetwork ? Icons.wifi : Icons.usb), size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                d != null ? '${d.name} · ${d.connectionTitle}' : (store.devicesLoading ? 'Поиск устройств…' : 'Нет устройства'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.unfold_more, size: 16),
          ],
        ),
      ),
    );
  }
}

/// Полоса текущей задачи внизу окна.
class JobStrip extends StatelessWidget {
  const JobStrip({super.key, required this.job, required this.more, required this.onOpen});
  final Job job;
  final int more;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: job,
    builder: (context, _) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          SizedBox(width: 120, child: LinearProgressIndicator(value: job.progress)),
          const SizedBox(width: 12),
          Text(job.title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(width: 10),
          Expanded(child: Muted(job.status, maxLines: 1)),
          if (more > 0) Muted('ещё $more', small: true),
          TextButton(onPressed: onOpen, child: const Text('Подробнее')),
        ],
      ),
    ),
  );
}
