import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/vault_store.dart';

/// Доступ к хранилищу из любого виджета; перестраивает зависимых при каждом изменении.
class StoreScope extends InheritedNotifier<VaultStore> {
  const StoreScope({super.key, required VaultStore store, required super.child}) : super(notifier: store);

  static VaultStore of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<StoreScope>()!.notifier!;
  static VaultStore read(BuildContext context) => context.getInheritedWidgetOfExactType<StoreScope>()!.notifier!;
}

class Gap {
  static const pad = 14.0;
  static const page = 20.0;
}

/// Карточка с заголовком и иконкой.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, this.title, this.icon, required this.children, this.trailing});
  final String? title;
  final IconData? icon;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(
              children: [
                if (icon != null) ...[Icon(icon, size: 18, color: scheme.onSurfaceVariant), const SizedBox(width: 8)],
                Expanded(
                  child: Text(title!, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 10),
          ],
          for (final (i, child) in children.indexed) ...[if (i > 0) const SizedBox(height: 8), child],
        ],
      ),
    );
  }
}

class KeyValue extends StatelessWidget {
  const KeyValue(this.label, this.value, {super.key, this.keyWidth = 130, this.mono = false});
  final String label;
  final String value;
  final double keyWidth;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: keyWidth,
          child: Text(label, style: TextStyle(color: muted)),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: mono ? const TextStyle(fontFamily: 'Consolas', fontFamilyFallback: ['monospace']) : null,
          ),
        ),
      ],
    );
  }
}

class StateBadge extends StatelessWidget {
  const StateBadge(this.text, this.color, {super.key});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, required this.text, this.action});
  final IconData icon;
  final String title;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 44, color: muted),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(color: muted),
              ),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      ),
    );
  }
}

class ErrorLine extends StatelessWidget {
  const ErrorLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final red = Theme.of(context).colorScheme.error;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error, size: 16, color: red),
        const SizedBox(width: 6),
        Expanded(
          child: SelectableText(text, style: TextStyle(color: red)),
        ),
      ],
    );
  }
}

class WarningLine extends StatelessWidget {
  const WarningLine(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange),
      const SizedBox(width: 6),
      Expanded(
        child: Text(text, style: const TextStyle(color: Colors.orange)),
      ),
    ],
  );
}

class Muted extends StatelessWidget {
  const Muted(this.text, {super.key, this.small = false, this.maxLines});
  final String text;
  final bool small;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: small ? 12 : null),
  );
}

class AppIcon extends StatelessWidget {
  const AppIcon(this.path, {super.key, this.size = 32});
  final String path;
  final double size;

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    final radius = BorderRadius.circular(size * 0.22);
    if (!file.existsSync()) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: radius),
        child: Icon(Icons.apps, size: size * 0.6, color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
    }
    return ClipRRect(
      borderRadius: radius,
      child: Image.file(file, width: size, height: size, fit: BoxFit.cover),
    );
  }
}

/// Строка-кнопка поверх контекстного меню по правому клику.
Future<void> showContextMenu(BuildContext context, Offset position, List<PopupMenuEntry<VoidCallback>> entries) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final action = await showMenu<VoidCallback>(
    context: context,
    position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
    items: entries,
  );
  action?.call();
}

PopupMenuItem<VoidCallback> menuItem(String text, VoidCallback onTap, {bool enabled = true, bool destructive = false, IconData? icon}) =>
    PopupMenuItem<VoidCallback>(
      value: onTap,
      enabled: enabled,
      height: 36,
      child: Row(
        children: [
          if (icon != null) ...[Icon(icon, size: 18, color: destructive ? Colors.red : null), const SizedBox(width: 10)],
          Flexible(
            child: Text(text, style: destructive ? const TextStyle(color: Colors.red) : null),
          ),
        ],
      ),
    );

void copyText(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Скопировано: $text'), duration: const Duration(seconds: 2)));
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(error.toString()), backgroundColor: Theme.of(context).colorScheme.error, duration: const Duration(seconds: 6)),
  );
}

const _months = ['янв.', 'февр.', 'мар.', 'апр.', 'мая', 'июн.', 'июл.', 'авг.', 'сент.', 'окт.', 'нояб.', 'дек.'];

String formatDate(DateTime d) {
  final l = d.toLocal();
  return '${l.day} ${_months[l.month - 1]} ${l.year}';
}

String formatTime(DateTime d) {
  final l = d.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// Заголовок страницы с действиями справа.
class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {super.key, this.actions = const [], this.count});
  final String title;
  final List<Widget> actions;
  final int? count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.page, 16, Gap.page, 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
        if (count != null) ...[const SizedBox(width: 10), Padding(padding: const EdgeInsets.only(top: 8), child: CountBadge(count!))],
        const SizedBox(width: 16),
        Expanded(
          child: Wrap(
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: actions,
          ),
        ),
      ],
    ),
  );
}

class CountBadge extends StatelessWidget {
  const CountBadge(this.count, {super.key});
  final int count;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
    decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
    child: Text('$count', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
  );
}
