import 'package:flutter/material.dart';

import '../core/devices.dart';
import 'widgets.dart';

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final device = store.selectedDevice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          'Устройства',
          actions: [
            IconButton(onPressed: store.devicesLoading ? null : store.refreshDevices, icon: const Icon(Icons.refresh), tooltip: 'Обновить'),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: store.devices.isEmpty
              ? EmptyState(
                  icon: Icons.phonelink_off,
                  title: store.devicesLoading ? 'Поиск устройств…' : 'Устройств нет',
                  text:
                      'Подключите iPhone кабелем, разблокируйте и нажмите «Доверять». Windows видит iPhone через службу '
                      'Apple Mobile Device — она ставится вместе с приложением «Устройства Apple» (Microsoft Store) или iTunes. '
                      'Для работы по Wi‑Fi один раз включите там «Показывать этот iPhone при подключении к Wi‑Fi».',
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 260,
                      child: ListView(
                        children: [
                          for (final d in store.devices)
                            ListTile(
                              selected: d.udid == device?.udid,
                              leading: Icon(d.useNetwork ? Icons.wifi : Icons.usb),
                              title: Text(d.name),
                              subtitle: Text('${d.modelName} · iOS ${d.productVersion}'),
                              onTap: () => store.selectDevice(d.udid),
                            ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    if (device != null)
                      Expanded(
                        child: DeviceDetail(key: ValueKey(device.udid), device: device),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class DeviceDetail extends StatefulWidget {
  const DeviceDetail({super.key, required this.device});
  final Device device;

  @override
  State<DeviceDetail> createState() => _DeviceDetailState();
}

class _DeviceDetailState extends State<DeviceDetail> {
  bool _loading = false;
  String? _error;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    if (StoreScope.read(context).installedApps[widget.device.udid] == null) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await StoreScope.read(context).loadApps(widget.device);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _menu(BuildContext context, Offset position, InstalledApp app) {
    final store = StoreScope.read(context);
    final device = widget.device;
    showContextMenu(context, position, [
      if (app.isAppStore) ...[
        menuItem(
          store.account == null ? 'Скачать в библиотеку — нужен вход в App Store' : 'Скачать в библиотеку',
          () => store.downloadInstalled(app, device),
          enabled: store.account != null,
          icon: Icons.download,
        ),
        const PopupMenuDivider(),
      ],
      menuItem('Удалить с устройства', () => store.uninstall(app, device), destructive: true, icon: Icons.delete_outline),
      menuItem('Скопировать bundle ID', () => copyText(context, app.bundleID), icon: Icons.copy),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final d = widget.device;
    final all = store.installedApps[d.udid];
    final q = _filter.toLowerCase();
    final apps = (all ?? const <InstalledApp>[])
        .where((a) => q.isEmpty || a.name.toLowerCase().contains(q) || a.bundleID.toLowerCase().contains(q))
        .toList();
    final both = d.connections.contains(Connection.usb) && d.connections.contains(Connection.network);
    return Padding(
      padding: const EdgeInsets.all(Gap.page),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionCard(
            title: d.name,
            icon: Icons.phone_iphone,
            children: [
              KeyValue('Модель', '${d.modelName} (${d.productType})', keyWidth: 170),
              KeyValue('iOS', '${d.productVersion} (${d.buildVersion})', keyWidth: 170),
              KeyValue('UDID', d.udid, keyWidth: 170, mono: true),
              KeyValue('Подключение', both ? 'USB и Wi‑Fi' : d.connectionTitle, keyWidth: 170),
              Row(
                children: [
                  SizedBox(width: 170, child: Muted('Режим разработчика')),
                  switch (d.developerMode) {
                    true => const StateBadge('включён', Colors.green),
                    false => Row(
                      children: [
                        const StateBadge('выключен', Colors.orange),
                        const SizedBox(width: 10),
                        TextButton(onPressed: () => store.revealDeveloperMode(d), child: const Text('Показать в Настройках iPhone')),
                      ],
                    ),
                    null => const Muted('неизвестно'),
                  },
                ],
              ),
              Wrap(
                spacing: 8,
                children: [
                  Tooltip(
                    message: store.hasASCKey
                        ? 'Добавить UDID в команду через App Store Connect API'
                        : 'Нужен ключ App Store Connect API (вкладка «Подпись»)',
                    child: OutlinedButton(
                      onPressed: store.hasASCKey ? () => store.registerDevice(d) : null,
                      child: const Text('Зарегистрировать в аккаунте разработчика'),
                    ),
                  ),
                  OutlinedButton(onPressed: () => copyText(context, d.udid), child: const Text('Скопировать UDID')),
                ],
              ),
            ],
          ),
          const SizedBox(height: Gap.pad),
          Row(
            children: [
              Text('Установленные приложения', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              if (all != null) ...[const SizedBox(width: 8), CountBadge(all.length)],
              const Spacer(),
              SizedBox(
                width: 220,
                child: TextField(
                  decoration: const InputDecoration(hintText: 'Фильтр', isDense: true, border: OutlineInputBorder()),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
              const SizedBox(width: 8),
              if (_loading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh), tooltip: 'Обновить'),
            ],
          ),
          if (_error != null) ErrorLine(_error!),
          const SizedBox(height: 6),
          const _HeaderRow(),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: apps.length,
              itemBuilder: (context, i) {
                final app = apps[i];
                return GestureDetector(
                  onSecondaryTapDown: (e) => _menu(context, e.globalPosition, app),
                  child: Container(
                    color: i.isOdd ? Theme.of(context).colorScheme.surfaceContainerLow : null,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                              Muted(app.bundleID, small: true, maxLines: 1),
                            ],
                          ),
                        ),
                        SizedBox(width: 120, child: Text(app.version)),
                        SizedBox(
                          width: 130,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: app.isAppStore
                                ? const StateBadge('App Store', Colors.blue)
                                : const StateBadge('Разработчик', Colors.purple),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(
      children: [
        Expanded(child: Muted('Приложение')),
        SizedBox(width: 120, child: Muted('Версия')),
        SizedBox(width: 130, child: Muted('Подпись')),
      ],
    ),
  );
}
