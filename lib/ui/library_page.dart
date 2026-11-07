import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/devices.dart';
import '../core/ipa.dart';
import '../core/library.dart';
import '../state/settings.dart';
import '../state/vault_store.dart';
import 'widgets.dart';

const _ipaTypes = [
  XTypeGroup(label: 'IPA', extensions: ['ipa']),
];

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  String _query = '';
  String? _selected;
  bool _dropping = false;

  List<LibraryItem> _filtered(VaultStore store) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return store.items;
    return store.items
        .where((i) => i.info.name.toLowerCase().contains(q) || i.info.bundleID.toLowerCase().contains(q) || i.info.version.contains(q))
        .toList();
  }

  Future<void> _import(VaultStore store) async {
    final files = await openFiles(acceptedTypeGroups: _ipaTypes);
    store.importFiles(files.map((f) => f.path).toList());
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final items = _filtered(store);
    final selected = store.items.where((i) => i.id == _selected).firstOrNull ?? items.firstOrNull;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dropping = true),
      onDragExited: (_) => setState(() => _dropping = false),
      onDragDone: (details) {
        setState(() => _dropping = false);
        store.importFiles(details.files.map((f) => f.path).where((path) => path.toLowerCase().endsWith('.ipa')).toList());
      },
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageHeader(
                'Библиотека',
                count: store.items.length,
                actions: [
                  SizedBox(
                    width: 240,
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'Название или bundle ID',
                        prefixIcon: Icon(Icons.search, size: 18),
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () => _import(store),
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('Импорт IPA'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => showDialog(context: context, builder: (_) => const CacheScanDialog()),
                    icon: const Icon(Icons.travel_explore),
                    label: const Text('Найти на диске'),
                  ),
                ],
              ),
              const Divider(height: 1),
              Expanded(
                child: store.items.isEmpty
                    ? EmptyState(
                        icon: Icons.inventory_2_outlined,
                        title: 'Библиотека пуста',
                        text:
                            'Перетащите сюда .ipa, скачайте свои покупки на вкладке «App Store» или найдите IPA, '
                            'которые уже есть на диске: медиатека iTunes, iMazing, 3uTools, «Загрузки».',
                        action: FilledButton(onPressed: () => _import(store), child: const Text('Выбрать .ipa…')),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: ListView.separated(
                              itemCount: items.length,
                              separatorBuilder: (_, _) => const Divider(height: 1, indent: 64),
                              itemBuilder: (context, i) => _ItemRow(
                                item: items[i],
                                selected: items[i].id == selected?.id,
                                onTap: () => setState(() => _selected = items[i].id),
                                onInstall: () => showInstallDialog(context, items[i]),
                              ),
                            ),
                          ),
                          const VerticalDivider(width: 1),
                          SizedBox(
                            width: 380,
                            child: selected == null
                                ? const EmptyState(
                                    icon: Icons.info_outline,
                                    title: 'Ничего не выбрано',
                                    text: 'Выберите приложение в списке',
                                  )
                                : ItemDetail(item: selected),
                          ),
                        ],
                      ),
              ),
            ],
          ),
          if (_dropping)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
                    borderRadius: BorderRadius.circular(12),
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.06),
                  ),
                  child: const Center(child: Text('Отпустите, чтобы добавить в библиотеку')),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.selected, required this.onTap, required this.onInstall});
  final LibraryItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.read(context);
    return GestureDetector(
      onSecondaryTapDown: (d) {
        onTap();
        showContextMenu(context, d.globalPosition, [
          menuItem('Установить на устройство…', onInstall, icon: Icons.install_mobile),
          if (item.info.kind == IPAKind.resignable)
            menuItem('Переподписать в библиотеку', () => store.resignToLibrary(item), icon: Icons.draw),
          menuItem('Показать в Проводнике', () => store.reveal(store.storage.ipaPath(item)), icon: Icons.folder_open),
          const PopupMenuDivider(),
          menuItem('Удалить из библиотеки', () => store.delete({item.id}), destructive: true, icon: Icons.delete_outline),
        ]);
      },
      // На узком окне источник и дата прячутся — остаются название, версия и тип.
      child: LayoutBuilder(
        builder: (context, c) => ListTile(
          selected: selected,
          selectedTileColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
          onTap: onTap,
          leading: AppIcon(store.storage.iconPath(item), size: 36),
          title: Text(item.info.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(item.info.bundleID, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: c.maxWidth < 480
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 80,
                      child: Text(
                        item.info.version,
                        textAlign: TextAlign.end,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: 16),
                    SizedBox(
                      width: 170,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: KindBadge(item: item),
                      ),
                    ),
                    if (c.maxWidth >= 760) ...[
                      SizedBox(width: 110, child: Muted(item.source.title, maxLines: 1)),
                      SizedBox(width: 100, child: Muted(formatDate(item.addedAt), small: true)),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

class KindBadge extends StatelessWidget {
  const KindBadge({super.key, required this.item});
  final LibraryItem item;

  @override
  Widget build(BuildContext context) {
    final until = item.signedUntil;
    if (until != null) {
      final expired = until.isBefore(DateTime.now());
      return StateBadge(expired ? 'подпись истекла' : 'подписано до ${formatDate(until)}', expired ? Colors.red : Colors.purple);
    }
    return item.info.kind == IPAKind.appStore
        ? const StateBadge('App Store', Colors.blue)
        : const StateBadge('без шифрования', Colors.green);
  }
}

class ItemDetail extends StatelessWidget {
  const ItemDetail({super.key, required this.item});
  final LibraryItem item;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final info = item.info;
    final meta = info.store;
    final profile = info.embeddedProfile;
    return ListView(
      padding: const EdgeInsets.all(Gap.pad),
      children: [
        Row(
          children: [
            AppIcon(store.storage.iconPath(item), size: 64),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(info.name, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  Muted('${info.version} (${info.build})'),
                  const SizedBox(height: 4),
                  KindBadge(item: item),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.pad),
        SectionCard(
          title: 'Установка',
          icon: Icons.install_mobile,
          children: [
            Muted(_explanation(info)),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: store.devices.isEmpty ? null : () => showInstallDialog(context, item),
                  icon: const Icon(Icons.download_for_offline_outlined),
                  label: Text(store.selectedDevice != null ? 'На ${store.selectedDevice!.name}' : 'Установить…'),
                ),
                if (info.kind == IPAKind.resignable)
                  OutlinedButton(onPressed: () => store.resignToLibrary(item), child: const Text('Переподписать')),
              ],
            ),
          ],
        ),
        const SizedBox(height: Gap.pad),
        SectionCard(
          title: 'Сведения',
          icon: Icons.info_outline,
          children: [
            KeyValue('Bundle ID', info.bundleID, keyWidth: 110, mono: true),
            KeyValue('Мин. iOS', info.minimumOS ?? '', keyWidth: 110),
            KeyValue('Архитектуры', info.architectures.join(', '), keyWidth: 110),
            KeyValue('Шифрование', switch (info.encryption) {
              EncryptionState.encrypted => 'FairPlay (сборка App Store)',
              EncryptionState.decrypted => 'нет',
              EncryptionState.unknown => 'не определено',
            }, keyWidth: 110),
            KeyValue('Расширения', info.extensions.map(p.posix.basename).join(', '), keyWidth: 110),
            KeyValue('Watch', info.hasWatchApp ? 'есть' : '', keyWidth: 110),
            KeyValue('Размер', formatSize(info.fileSize), keyWidth: 110),
            KeyValue('Источник', item.source.title, keyWidth: 110),
          ],
        ),
        if (meta != null) ...[
          const SizedBox(height: Gap.pad),
          SectionCard(
            title: 'App Store',
            icon: Icons.shopping_bag_outlined,
            children: [
              KeyValue('Купил', meta.purchaserAppleID ?? '', keyWidth: 110),
              KeyValue('Дата покупки', meta.purchaseDate != null ? formatDate(meta.purchaseDate!) : '', keyWidth: 110),
              KeyValue('ID в магазине', meta.itemID?.toString() ?? '', keyWidth: 110, mono: true),
              KeyValue('ID версии', meta.externalVersionID?.toString() ?? '', keyWidth: 110, mono: true),
              KeyValue('Разработчик', meta.artistName ?? '', keyWidth: 110),
            ],
          ),
        ],
        if (profile != null) ...[
          const SizedBox(height: Gap.pad),
          SectionCard(
            title: 'Подпись',
            icon: Icons.draw_outlined,
            children: [
              KeyValue('Профиль', profile.name, keyWidth: 110),
              KeyValue('Команда', '${profile.teamName} (${profile.teamID})', keyWidth: 110),
              KeyValue('Действует до', formatDate(profile.expiration), keyWidth: 110),
              KeyValue('Устройства', profile.provisionsAllDevices ? 'все (enterprise)' : '${profile.deviceCount}', keyWidth: 110),
            ],
          ),
        ],
        const SizedBox(height: Gap.pad),
        Row(
          children: [
            TextButton(onPressed: () => store.reveal(store.storage.ipaPath(item)), child: const Text('Показать в Проводнике')),
            const Spacer(),
            TextButton(
              onPressed: () => store.delete({item.id}),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Удалить'),
            ),
          ],
        ),
      ],
    );
  }

  String _explanation(IPAInfo info) {
    if (info.kind == IPAKind.appStore) {
      final who = info.store?.purchaserAppleID != null ? ' (${info.store!.purchaserAppleID})' : '';
      return 'Сборка App Store подписана Apple и не истекает. Ставится как есть на iPhone, где выполнен вход '
          'в App Store с тем же Apple ID$who — в том числе после удаления приложения из магазина. '
          'Переподписать её нельзя: бинарник зашифрован.';
    }
    return 'Незашифрованное приложение: подписывается вашим сертификатом разработчика и ставится на зарегистрированные '
        'устройства. С платным аккаунтом подпись действует до года.';
  }
}

Future<void> showInstallDialog(BuildContext context, LibraryItem item) => showDialog(
  context: context,
  builder: (_) => InstallDialog(item: item),
);

class InstallDialog extends StatefulWidget {
  const InstallDialog({super.key, required this.item});
  final LibraryItem item;

  @override
  State<InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<InstallDialog> {
  String? _deviceID;
  var _method = InstallMethod.resign;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final item = widget.item;
    final device = store.devices.where((d) => d.udid == _deviceID).firstOrNull ?? store.selectedDevice;
    final warning = _warning(store, device);
    final options = store.settings.options;
    return AlertDialog(
      title: Row(
        children: [
          AppIcon(store.storage.iconPath(item), size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Text('Установка ${item.info.name}'), Muted('${item.info.bundleID} · ${item.info.version}', small: true)],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: device?.udid,
              decoration: const InputDecoration(labelText: 'Устройство', border: OutlineInputBorder()),
              items: [
                for (final d in store.devices)
                  DropdownMenuItem(value: d.udid, child: Text('${d.name} — iOS ${d.productVersion}, ${d.connectionTitle}')),
              ],
              onChanged: (v) => setState(() => _deviceID = v),
            ),
            if (item.info.kind == IPAKind.resignable) ...[
              const SizedBox(height: 12),
              RadioGroup<InstallMethod>(
                groupValue: _method,
                onChanged: (v) => setState(() => _method = v ?? _method),
                child: Column(
                  children: [
                    for (final m in InstallMethod.values)
                      RadioListTile<InstallMethod>(value: m, title: Text(m.title), dense: true, contentPadding: EdgeInsets.zero),
                  ],
                ),
              ),
              if (_method == InstallMethod.resign) ...[
                Muted('${store.settings.signingMode.title} · ${store.chosenIdentity?.shortName ?? 'сертификат не найден'}', small: true),
                CheckboxListTile(
                  value: options.removeExtensions,
                  onChanged: (v) => setState(() {
                    options.removeExtensions = v ?? false;
                    store.saveSettings();
                  }),
                  title: const Text('Убрать расширения (виджеты, шаринг)'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                CheckboxListTile(
                  value: options.removeWatchApp,
                  onChanged: (v) => setState(() {
                    options.removeWatchApp = v ?? true;
                    store.saveSettings();
                  }),
                  title: const Text('Убрать приложение для часов'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ],
            if (warning != null) ...[const SizedBox(height: 12), WarningLine(warning)],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(
          onPressed: device == null
              ? null
              : () {
                  store.install(item, device, _method);
                  Navigator.pop(context);
                },
          child: const Text('Установить'),
        ),
      ],
    );
  }

  String? _warning(VaultStore store, Device? device) {
    final item = widget.item;
    if (device == null) return 'Нет подключённого устройства';
    final need = item.info.minimumOS;
    if (need != null && device.productVersion.isNotEmpty && compareVersions(device.productVersion, need) < 0) {
      return 'Нужна iOS $need, на устройстве ${device.productVersion}';
    }
    if (item.info.kind == IPAKind.appStore) {
      final who = item.info.store?.purchaserAppleID ?? 'Apple ID, которым приложение получено';
      return 'На iPhone должен быть выполнен вход в App Store с $who. С другим Apple ID приложение установится, но не запустится.';
    }
    if (_method == InstallMethod.resign && device.developerMode == false) {
      return 'На устройстве выключен режим разработчика — переподписанное приложение не запустится. Включить можно на вкладке «Устройства».';
    }
    if (_method == InstallMethod.resign && store.settings.signingMode == SigningMode.manual && store.profiles.isEmpty) {
      return 'Нет ни одного профиля: добавьте .mobileprovision на вкладке «Подпись» или включите режим App Store Connect API.';
    }
    return null;
  }
}

class CacheScanDialog extends StatefulWidget {
  const CacheScanDialog({super.key});

  @override
  State<CacheScanDialog> createState() => _CacheScanDialogState();
}

class _CacheScanDialogState extends State<CacheScanDialog> {
  List<FoundIPA>? _found;
  final _chosen = <String>{};

  @override
  void initState() {
    super.initState();
    final extra = StoreScope.read(context).settings.extraScanFolders.split('\n');
    CacheScanner.scan(CacheScanner.locations(extra)).then((f) {
      if (mounted) setState(() => _found = f);
    });
  }

  @override
  Widget build(BuildContext context) {
    final found = _found;
    return AlertDialog(
      title: const Text('IPA на диске'),
      content: SizedBox(
        width: 620,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Muted('Медиатека iTunes, iMazing, 3uTools, «Загрузки» и «Рабочий стол», а также папки из настроек.'),
            const SizedBox(height: 10),
            Expanded(
              child: found == null
                  ? const Center(child: CircularProgressIndicator())
                  : found.isEmpty
                  ? const EmptyState(
                      icon: Icons.search_off,
                      title: 'Ничего не найдено',
                      text: 'Скачайте свои покупки на вкладке «App Store» или добавьте папку с архивом IPA в настройках.',
                    )
                  : ListView(
                      children: [
                        for (final f in found)
                          CheckboxListTile(
                            value: _chosen.contains(f.path),
                            onChanged: (on) => setState(() => on == true ? _chosen.add(f.path) : _chosen.remove(f.path)),
                            title: Text(p.basename(f.path), maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text('${f.location} · ${formatSize(f.size)} · ${formatDate(f.modified)}'),
                            dense: true,
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: found == null || found.isEmpty ? null : () => setState(() => _chosen.addAll(found.map((f) => f.path))),
          child: const Text('Выбрать все'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(
          onPressed: _chosen.isEmpty
              ? null
              : () {
                  final store = StoreScope.read(context);
                  for (final f in found!.where((f) => _chosen.contains(f.path))) {
                    store.importFiles([f.path], source: CacheSource(f.location));
                  }
                  Navigator.pop(context);
                },
          child: Text('Импортировать (${_chosen.length})'),
        ),
      ],
    );
  }
}
