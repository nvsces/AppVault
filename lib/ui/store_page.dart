import 'package:flutter/material.dart';

import '../core/ipatool.dart';
import '../core/tools.dart';
import 'widgets.dart';

class StorePage extends StatefulWidget {
  const StorePage({super.key});

  @override
  State<StorePage> createState() => _StorePageState();
}

class _StorePageState extends State<StorePage> {
  var _tab = 0;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final account = store.account;
    if (Toolbox.path(Tool.ipatool) == null) {
      return const EmptyState(
        icon: Icons.shopping_bag_outlined,
        title: 'Нужен ipatool',
        text:
            'Скачивание из App Store работает через ipatool. Положите ipatool.exe в папку tools рядом с AppVault '
            'или укажите папку с утилитами в настройках.',
      );
    }
    if (!store.accountChecked) return const Center(child: CircularProgressIndicator());
    if (account == null) return const LoginPane();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          'App Store',
          actions: [
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Мои покупки')),
                ButtonSegment(value: 1, label: Text('Поиск')),
                ButtonSegment(value: 2, label: Text('По ID или ссылке')),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.first),
            ),
            const SizedBox(width: 12),
            const Icon(Icons.account_circle_outlined, size: 18),
            Muted(account.email),
            TextButton(onPressed: store.logout, child: const Text('Выйти')),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: IndexedStack(index: _tab, children: const [PurchasesPane(), SearchPane(), ByIDPane()]),
        ),
      ],
    );
  }
}

class LoginPane extends StatefulWidget {
  const LoginPane({super.key});

  @override
  State<LoginPane> createState() => _LoginPaneState();
}

class _LoginPaneState extends State<LoginPane> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _needsCode = false;
  bool _busy = false;
  String? _error;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await IPATool.login(_email.text.trim(), _password.text, _needsCode ? _code.text.trim() : null);
      if (!mounted) return;
      switch (r) {
        case LoginSuccess(account: final account):
          _password.clear();
          StoreScope.read(context).setAccount(account);
        case LoginNeedsCode():
          setState(() => _needsCode = true);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = !_busy && _email.text.isNotEmpty && _password.text.isNotEmpty && (!_needsCode || _code.text.isNotEmpty);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Вход в App Store', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Muted(
                'Нужен, чтобы скачивать свои покупки и их старые версии — в том числе приложения, снятые с продажи, '
                'пока они остаются в истории покупок. Вход выполняет ipatool; его токен хранится в зашифрованном файле, '
                'пароль Apple ID AppVault не сохраняет.',
              ),
              const SizedBox(height: 16),
              SectionCard(
                children: [
                  TextField(
                    controller: _email,
                    decoration: const InputDecoration(labelText: 'Apple ID', border: OutlineInputBorder()),
                    onChanged: (_) => setState(() {}),
                  ),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Пароль', border: OutlineInputBorder()),
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => ready ? _login() : null,
                  ),
                  if (_needsCode) ...[
                    TextField(
                      controller: _code,
                      decoration: const InputDecoration(labelText: 'Код двухфакторной аутентификации', border: OutlineInputBorder()),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => ready ? _login() : null,
                    ),
                    const Muted('Apple отправила код на доверенные устройства — введите его и нажмите «Войти» ещё раз'),
                  ],
                  if (_error != null) ErrorLine(_error!),
                  Row(
                    children: [
                      const Spacer(),
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      FilledButton(onPressed: ready ? _login : null, child: const Text('Войти')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Muted('Первый вход может занять пару минут — ipatool готовит данные для авторизации.', small: true),
            ],
          ),
        ),
      ),
    );
  }
}

/// Строка приложения из магазина с кнопками «Версии» и «Скачать».
class StoreAppRow extends StatelessWidget {
  const StoreAppRow({super.key, required this.app, this.selected, this.onSelect});
  final StoreApp app;
  final bool? selected;
  final ValueChanged<bool>? onSelect;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final inLibrary = store.items.any((i) => i.info.bundleID == app.bundleID && i.info.version == app.version);
    final details = [
      app.bundleID,
      if (app.version.isNotEmpty) 'v${app.version}',
      'ID ${app.id}',
      if (app.price > 0) app.price.toStringAsFixed(2),
      if (app.purchaseDate != null) 'куплено ${formatDate(app.purchaseDate!)}',
    ].join(' · ');
    return ListTile(
      leading: selected == null ? null : Checkbox(value: selected, onChanged: (v) => onSelect?.call(v ?? false)),
      title: Row(
        children: [
          Flexible(child: Text(app.name.isEmpty ? app.bundleID : app.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (inLibrary) ...[const SizedBox(width: 8), const StateBadge('в библиотеке', Colors.green)],
        ],
      ),
      subtitle: Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton(
            onPressed: () => showDialog(
              context: context,
              builder: (_) => VersionsDialog(app: app),
            ),
            child: const Text('Версии'),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: () => store.download(app.id, app.bundleID, app.name), child: const Text('Скачать')),
        ],
      ),
    );
  }
}

class PurchasesPane extends StatefulWidget {
  const PurchasesPane({super.key});

  @override
  State<PurchasesPane> createState() => _PurchasesPaneState();
}

class _PurchasesPaneState extends State<PurchasesPane> {
  List<StoreApp> _apps = [];
  bool _loading = false;
  int _loaded = 0, _total = 0;
  String? _error;
  String _filter = '';
  final _selection = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final apps = await IPATool.allPurchases(
        onPage: (done, all) {
          if (mounted) {
            setState(() {
              _loaded = done;
              _total = all;
            });
          }
        },
      );
      apps.sort((a, b) => (b.purchaseDate ?? DateTime(1970)).compareTo(a.purchaseDate ?? DateTime(1970)));
      if (mounted) setState(() => _apps = apps);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final q = _filter.toLowerCase();
    final shown = q.isEmpty ? _apps : _apps.where((a) => a.name.toLowerCase().contains(q) || a.bundleID.toLowerCase().contains(q)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 280,
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Фильтр: название или bundle ID',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
              if (_loading) ...[
                const SizedBox(width: 12),
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Muted('$_loaded из $_total'),
              ],
              const Spacer(),
              FilledButton.tonal(
                onPressed: _selection.isEmpty
                    ? null
                    : () {
                        for (final a in _apps.where((a) => _selection.contains(a.id))) {
                          store.download(a.id, a.bundleID, a.name);
                        }
                        setState(_selection.clear);
                      },
                child: Text('Скачать выбранные (${_selection.length})'),
              ),
              const SizedBox(width: 8),
              IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh), tooltip: 'Обновить'),
            ],
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.page),
            child: ErrorLine(_error!),
          ),
        Expanded(
          child: _apps.isEmpty && !_loading
              ? const EmptyState(
                  icon: Icons.shopping_bag_outlined,
                  title: 'Покупки не загружены',
                  text:
                      'Список всех приложений, когда-либо полученных этим Apple ID, включая снятые с продажи. '
                      'Сохраните нужные, пока их ещё можно скачать.',
                )
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (_, i) => StoreAppRow(
                    app: shown[i],
                    selected: _selection.contains(shown[i].id),
                    onSelect: (on) => setState(() => on ? _selection.add(shown[i].id) : _selection.remove(shown[i].id)),
                  ),
                ),
        ),
      ],
    );
  }
}

class SearchPane extends StatefulWidget {
  const SearchPane({super.key});

  @override
  State<SearchPane> createState() => _SearchPaneState();
}

class _SearchPaneState extends State<SearchPane> {
  final _term = TextEditingController();
  List<StoreApp> _results = [];
  bool _loading = false;
  String? _error;

  Future<void> _search() async {
    if (_term.text.trim().isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await IPATool.search(_term.text.trim());
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.page, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _term,
                decoration: const InputDecoration(hintText: 'Название приложения', isDense: true, border: OutlineInputBorder()),
                onSubmitted: (_) => _search(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _loading ? null : _search, child: const Text('Найти')),
            if (_loading)
              const Padding(
                padding: EdgeInsets.only(left: 12),
                child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
          ],
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.page),
          child: ErrorLine(_error!),
        ),
      Expanded(
        child: _results.isEmpty
            ? const EmptyState(
                icon: Icons.search,
                title: 'Поиск в App Store',
                text:
                    'Ищет в магазине региона вашего Apple ID. Снятых с продажи приложений в поиске нет — '
                    'ищите их в «Моих покупках» или скачивайте по числовому ID.',
              )
            : ListView(children: [for (final a in _results) StoreAppRow(app: a)]),
      ),
    ],
  );
}

class ByIDPane extends StatefulWidget {
  const ByIDPane({super.key});

  @override
  State<ByIDPane> createState() => _ByIDPaneState();
}

class _ByIDPaneState extends State<ByIDPane> {
  final _text = TextEditingController();
  final _version = TextEditingController();
  StoreApp? _found;
  bool _resolving = false;
  String? _error;

  String? get _bundleID => IPATool.parseBundleID(_text.text);
  int? get _appID => _bundleID == null ? IPATool.parseAppID(_text.text) : null;

  /// Числовой ID — сразу; bundle ID — сначала ищем в покупках, найденное запоминаем для следующей кнопки.
  Future<void> _resolve(void Function(StoreApp) action) async {
    setState(() => _error = null);
    final appID = _appID, bundleID = _bundleID;
    if (appID != null) return action(StoreApp(id: appID, bundleID: '', name: 'ID $appID', version: '', price: 0));
    if (bundleID == null) return;
    if (_found?.bundleID == bundleID) return action(_found!);
    setState(() => _resolving = true);
    try {
      final app = await IPATool.purchase(bundleID);
      if (!mounted) return;
      setState(() => _found = app);
      action(app);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final valid = _appID != null || _bundleID != null;
    final found = _found;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(Gap.page),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Muted(
                'Скачивание по числовому ID — единственный способ получить приложение, которое сняли с продажи: '
                'в поиске его нет, а по ID оно скачивается, если есть в покупках вашего Apple ID. '
                'ID — число из ссылки apps.apple.com/…/id123456789. Если известен только bundle ID, '
                'числовой ID найдётся в ваших покупках.',
              ),
              const SizedBox(height: 14),
              SectionCard(
                children: [
                  TextField(
                    controller: _text,
                    decoration: const InputDecoration(labelText: 'ID, ссылка App Store или bundle ID', border: OutlineInputBorder()),
                    onChanged: (_) => setState(() {}),
                  ),
                  TextField(
                    controller: _version,
                    decoration: const InputDecoration(
                      labelText: 'ID версии (необязательно)',
                      helperText: 'Внешний идентификатор версии из списка версий; пусто — последняя',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_text.text.isNotEmpty && !valid) const WarningLine('Не вижу ни числового ID, ни bundle ID'),
                  if (found != null && found.bundleID == _bundleID)
                    Muted('${found.name} · ID ${found.id} · последняя версия ${found.version}'),
                  if (_error != null) ErrorLine(_error!),
                  Row(
                    children: [
                      const Spacer(),
                      if (_resolving)
                        const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        ),
                      OutlinedButton(
                        onPressed: !valid || _resolving
                            ? null
                            : () => _resolve(
                                (app) => showDialog(
                                  context: context,
                                  builder: (_) => VersionsDialog(app: app),
                                ),
                              ),
                        child: const Text('Версии…'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: !valid || _resolving
                            ? null
                            : () => _resolve(
                                (app) => store.download(
                                  app.id,
                                  app.bundleID,
                                  app.name,
                                  versionID: _version.text.trim().isEmpty ? null : _version.text.trim(),
                                ),
                              ),
                        child: const Text('Скачать'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Все версии приложения из магазина. Номер версии и дата запрашиваются по одной — лениво, при показе строки.
class VersionsDialog extends StatefulWidget {
  const VersionsDialog({super.key, required this.app});
  final StoreApp app;

  @override
  State<VersionsDialog> createState() => _VersionsDialogState();
}

class _VersionsDialogState extends State<VersionsDialog> {
  List<String>? _versions;
  String? _error;
  final _meta = <String, ({String display, DateTime? date})?>{};

  @override
  void initState() {
    super.initState();
    IPATool.versions(widget.app.id, widget.app.bundleID).then(
      (v) {
        if (mounted) setState(() => _versions = v.reversed.toList());
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = e.toString());
      },
    );
  }

  void _loadMeta(String v) {
    if (_meta.containsKey(v)) return;
    _meta[v] = null;
    IPATool.versionMetadata(widget.app.id, widget.app.bundleID, v).then(
      (m) {
        if (mounted) setState(() => _meta[v] = m);
      },
      onError: (Object _) {
        if (mounted) setState(() => _meta[v] = (display: '—', date: null));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.read(context);
    final versions = _versions;
    return AlertDialog(
      title: Text('Версии ${widget.app.name}'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Muted('От новых к старым. Старую версию можно скачать, пока Apple хранит её на серверах.'),
            const SizedBox(height: 10),
            Expanded(
              child: _error != null
                  ? ErrorLine(_error!)
                  : versions == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: versions.length,
                      itemBuilder: (_, i) {
                        final v = versions[i];
                        _loadMeta(v);
                        final m = _meta[v];
                        return ListTile(
                          dense: true,
                          title: m == null
                              ? const Align(
                                  alignment: Alignment.centerLeft,
                                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                                )
                              : Text(m.display, style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text([if (m?.date != null) formatDate(m!.date!), v].join(' · ')),
                          trailing: OutlinedButton(
                            onPressed: () => store.download(widget.app.id, widget.app.bundleID, widget.app.name, versionID: v),
                            child: const Text('Скачать'),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))],
    );
  }
}
