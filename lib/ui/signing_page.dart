import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/provisioning.dart';
import '../core/resigner.dart';
import '../core/tools.dart';
import '../state/settings.dart';
import 'widgets.dart';

class SigningPage extends StatelessWidget {
  const SigningPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final s = store.settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          'Подпись',
          actions: [IconButton(onPressed: store.refreshSigning, icon: const Icon(Icons.refresh), tooltip: 'Обновить')],
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(Gap.page),
            children: [
              if (Toolbox.path(Tool.rcodesign) == null) ...[
                const WarningLine(
                  'Для переподписи нужен rcodesign.exe (apple-codesign). Положите его в папку tools рядом с AppVault '
                  'или укажите папку с утилитами в настройках. Сборки App Store ставятся и без него.',
                ),
                const SizedBox(height: Gap.pad),
              ],
              SectionCard(
                title: 'Режим',
                icon: Icons.tune,
                children: [
                  SegmentedButton<SigningMode>(
                    segments: [for (final m in SigningMode.values) ButtonSegment(value: m, label: Text(m.title))],
                    selected: {s.signingMode},
                    onSelectionChanged: (v) {
                      s.signingMode = v.first;
                      store.saveSettings();
                    },
                  ),
                  Muted(
                    s.signingMode == SigningMode.manual
                        ? 'Профили .mobileprovision, которые вы добавили сами (скачать можно на developer.apple.com → Profiles '
                              'или взять у Xcode на Mac). Для любых приложений нужен профиль с App ID «*», а устройство должно быть в нём.'
                        : 'AppVault сам регистрирует устройство, заводит App ID и выпускает профиль под каждое приложение через официальный '
                              'App Store Connect API. Bundle ID получает суффикс команды: чужой идентификатор в своей команде не зарегистрировать.',
                  ),
                ],
              ),
              const SizedBox(height: Gap.pad),
              const _IdentitiesCard(),
              if (s.signingMode == SigningMode.automatic) ...[const SizedBox(height: Gap.pad), const _ASCCard()],
              const SizedBox(height: Gap.pad),
              SectionCard(
                title: 'Параметры переподписи',
                icon: Icons.settings_suggest_outlined,
                children: [
                  SizedBox(
                    width: 420,
                    child: DropdownButtonFormField<BundleIDMode>(
                      isExpanded: true,
                      initialValue: s.options.bundleIDMode,
                      decoration: const InputDecoration(labelText: 'Bundle ID', border: OutlineInputBorder()),
                      items: [for (final m in BundleIDMode.values) DropdownMenuItem(value: m, child: Text(m.title))],
                      onChanged: (v) {
                        s.options.bundleIDMode = v ?? BundleIDMode.auto;
                        store.saveSettings();
                      },
                    ),
                  ),
                  CheckboxListTile(
                    value: s.options.removeExtensions,
                    onChanged: (v) {
                      s.options.removeExtensions = v ?? false;
                      store.saveSettings();
                    },
                    title: const Text('Убирать расширения (виджеты, шаринг, уведомления)'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  CheckboxListTile(
                    value: s.options.removeWatchApp,
                    onChanged: (v) {
                      s.options.removeWatchApp = v ?? true;
                      store.saveSettings();
                    },
                    title: const Text('Убирать приложение для Apple Watch'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                  const Muted('Расширениям нужны свои профили и права; если установка падает из‑за них — уберите расширения.', small: true),
                ],
              ),
              if (s.signingMode == SigningMode.manual) ...[const SizedBox(height: Gap.pad), const _ProfilesCard()],
            ],
          ),
        ),
      ],
    );
  }
}

class _IdentitiesCard extends StatelessWidget {
  const _IdentitiesCard();

  Future<void> _import(BuildContext context) async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Сертификат .p12', extensions: ['p12', 'pfx']),
      ],
    );
    if (file == null || !context.mounted) return;
    await showDialog(
      context: context,
      builder: (_) => _P12Dialog(path: file.path),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final chosen = store.chosenIdentity;
    return SectionCard(
      title: 'Сертификаты',
      icon: Icons.key_outlined,
      trailing: FilledButton.tonalIcon(onPressed: () => _import(context), icon: const Icon(Icons.add), label: const Text('Добавить .p12')),
      children: [
        if (store.identities.isEmpty)
          const Muted(
            'Сертификатов нет. На Mac: «Связка ключей» → «Мои сертификаты» → Apple Development → «Экспортировать» в .p12 '
            'с паролем. Закрытый ключ остаётся только на этом компьютере, пароль хранится под защитой Windows.',
          ),
        for (final id in store.identities)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(id.isValid ? Icons.verified_outlined : Icons.gpp_bad_outlined, color: id.isValid ? Colors.green : Colors.red),
            title: Text(id.name),
            subtitle: Text(
              [
                if (id.teamID != null) 'команда ${id.teamID}',
                if (id.expiration != null) '${id.isValid ? 'до' : 'истёк'} ${formatDate(id.expiration!)}',
                'SHA-1 ${id.sha1.substring(0, 8)}…',
              ].join(' · '),
            ),
            trailing: IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline), onPressed: () => store.removeIdentity(id)),
          ),
        if (store.identities.length > 1)
          DropdownButtonFormField<String?>(
            isExpanded: true,
            initialValue: store.settings.identitySHA1,
            decoration: const InputDecoration(labelText: 'Подписывать', border: OutlineInputBorder()),
            items: [
              const DropdownMenuItem(value: null, child: Text('Автоматически')),
              for (final id in store.identities) DropdownMenuItem(value: id.sha1, child: Text('${id.name}${id.isValid ? '' : ' — истёк'}')),
            ],
            onChanged: (v) {
              store.settings.identitySHA1 = v;
              store.saveSettings();
            },
          ),
        if (chosen != null) KeyValue('Будет использован', chosen.name, keyWidth: 150),
      ],
    );
  }
}

class _P12Dialog extends StatefulWidget {
  const _P12Dialog({required this.path});
  final String path;

  @override
  State<_P12Dialog> createState() => _P12DialogState();
}

class _P12DialogState extends State<_P12Dialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await StoreScope.read(context).importIdentity(widget.path, _password.text);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Пароль к ${p.basename(widget.path)}'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _password,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Пароль, заданный при экспорте', border: OutlineInputBorder()),
            onSubmitted: (_) => _busy ? null : _save(),
          ),
          if (_error != null) ...[const SizedBox(height: 10), ErrorLine(_error!)],
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Добавить')),
    ],
  );
}

class _ASCCard extends StatefulWidget {
  const _ASCCard();

  @override
  State<_ASCCard> createState() => _ASCCardState();
}

class _ASCCardState extends State<_ASCCard> {
  late final _issuer = TextEditingController(text: StoreScope.read(context).settings.ascIssuerID);
  late final _keyID = TextEditingController(text: StoreScope.read(context).settings.ascKeyID);
  String? _keyPEM;
  String? _keyFile;
  String? _error;

  Future<void> _pickKey() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Ключ .p8', extensions: ['p8']),
      ],
    );
    if (file == null) return;
    final pem = await File(file.path).readAsString();
    // AuthKey_ABCD123456.p8 — Key ID прямо в имени файла.
    final m = RegExp(r'AuthKey_([A-Z0-9]+)\.p8').firstMatch(p.basename(file.path));
    setState(() {
      _keyPEM = pem;
      _keyFile = p.basename(file.path);
      if (_keyID.text.isEmpty && m != null) _keyID.text = m.group(1)!;
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return SectionCard(
      title: 'App Store Connect API',
      icon: Icons.vpn_key_outlined,
      children: [
        const Muted(
          'App Store Connect → Users and Access → Integrations → App Store Connect API: создайте ключ с ролью Developer '
          'или Admin и скачайте .p8 (скачать можно один раз). Для индивидуального ключа Issuer ID оставьте пустым.',
        ),
        TextField(
          controller: _issuer,
          decoration: const InputDecoration(labelText: 'Issuer ID', border: OutlineInputBorder()),
        ),
        TextField(
          controller: _keyID,
          decoration: const InputDecoration(labelText: 'Key ID', border: OutlineInputBorder()),
          onChanged: (_) => setState(() {}),
        ),
        Row(
          children: [
            const SizedBox(width: 130, child: Muted('Закрытый ключ')),
            Expanded(child: Muted(_keyFile ?? (store.hasASCKey ? 'сохранён (DPAPI)' : 'не задан'))),
            OutlinedButton(onPressed: _pickKey, child: const Text('Выбрать .p8…')),
          ],
        ),
        if (_error != null) ErrorLine(_error!),
        Row(
          children: [
            if (store.hasASCKey)
              TextButton(
                onPressed: store.removeASCKey,
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Удалить ключ'),
              ),
            const Spacer(),
            OutlinedButton(onPressed: store.hasASCKey ? store.testASC : null, child: const Text('Проверить доступ')),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _keyID.text.isEmpty || (_keyPEM == null && !store.hasASCKey)
                  ? null
                  : () {
                      try {
                        store.saveASC(issuerID: _issuer.text, keyID: _keyID.text, keyPEM: _keyPEM);
                        setState(() {
                          _keyPEM = null;
                          _error = null;
                        });
                      } catch (e) {
                        setState(() => _error = e.toString());
                      }
                    },
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ProfilesCard extends StatelessWidget {
  const _ProfilesCard();

  Future<void> _import(BuildContext context) async {
    final files = await openFiles(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Профиль', extensions: ['mobileprovision']),
      ],
    );
    if (!context.mounted) return;
    final store = StoreScope.read(context);
    for (final f in files) {
      try {
        store.importProfile(f.path);
      } catch (e) {
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final identity = store.chosenIdentity;
    final List<ProvisioningProfile> list = identity == null
        ? store.profiles
        : store.profiles.where((pr) => pr.certificateSHA1s.contains(identity.sha1)).toList();
    final hidden = store.profiles.length - list.length;
    final device = store.selectedDevice;
    return SectionCard(
      title: 'Профили',
      icon: Icons.description_outlined,
      trailing: FilledButton.tonalIcon(
        onPressed: () => _import(context),
        icon: const Icon(Icons.add),
        label: const Text('Добавить .mobileprovision'),
      ),
      children: [
        DropdownButtonFormField<String?>(
          isExpanded: true,
          initialValue: list.any((pr) => pr.uuid == store.settings.pinnedProfileUUID) ? store.settings.pinnedProfileUUID : null,
          decoration: const InputDecoration(labelText: 'Профиль', border: OutlineInputBorder()),
          items: [
            const DropdownMenuItem(value: null, child: Text('Подбирать автоматически')),
            for (final pr in list.where((pr) => !pr.isExpired))
              DropdownMenuItem(
                value: pr.uuid,
                child: Text('${pr.name} — ${pr.applicationIdentifier}', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) {
            store.settings.pinnedProfileUUID = v;
            store.saveSettings();
          },
        ),
        if (list.isEmpty)
          const Muted(
            'Профилей нет. Создайте на developer.apple.com → Certificates, IDs & Profiles → Profiles профиль '
            'iOS App Development с App ID «*», своим сертификатом и устройством — или включите режим App Store Connect API.',
          ),
        if (hidden > 0) Muted('Ещё $hidden — для других сертификатов', small: true),
        for (final pr in list)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Row(
              children: [
                Flexible(child: Text(pr.name, overflow: TextOverflow.ellipsis)),
                if (pr.bundlePattern == '*') ...[const SizedBox(width: 8), const StateBadge('любой App ID', Colors.green)],
              ],
            ),
            subtitle: Text('${pr.applicationIdentifier} · ${pr.kind.title} · устройств: ${pr.devices.length}'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (device != null)
                  Tooltip(
                    message: pr.includes(device.udid) ? '${device.name} есть в профиле' : '${device.name} нет в профиле',
                    child: Icon(
                      pr.includes(device.udid) ? Icons.mobile_friendly : Icons.phonelink_erase,
                      color: pr.includes(device.udid) ? Colors.green : null,
                      size: 20,
                    ),
                  ),
                const SizedBox(width: 12),
                Text(
                  pr.isExpired ? 'истёк' : 'до ${formatDate(pr.expiration)}',
                  style: TextStyle(color: pr.isExpired ? Colors.red : null, fontSize: 12),
                ),
                IconButton(tooltip: 'Удалить', icon: const Icon(Icons.delete_outline), onPressed: () => store.removeProfile(pr)),
              ],
            ),
          ),
      ],
    );
  }
}
