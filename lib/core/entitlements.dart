/// Права (entitlements) для переподписи. Подпись с правами, которых нет в профиле, iOS отвергнет
/// при установке, поэтому берём права исходного приложения и оставляем только разрешённые профилем.
class Entitlements {
  static const identityKeys = {'application-identifier', 'com.apple.developer.team-identifier', 'get-task-allow', 'keychain-access-groups'};

  /// `dropped` — права исходного приложения, которые профиль не разрешает: функции на них работать не будут.
  static ({Map<String, dynamic> entitlements, List<String> dropped}) build({
    required Map<String, dynamic> profile,
    required String teamID,
    required String bundleID,
    required Map<String, dynamic> original,
  }) {
    final result = <String, dynamic>{'application-identifier': '$teamID.$bundleID', 'com.apple.developer.team-identifier': teamID};
    if (profile['get-task-allow'] is bool) result['get-task-allow'] = profile['get-task-allow'];

    // Группы связки ключей: префикс чужой команды меняем на свой, лишнее отбрасываем.
    final allowedGroups = (profile['keychain-access-groups'] as List?)?.whereType<String>().toList() ?? ['$teamID.*'];
    final groups = <String>[];
    for (final g in (original['keychain-access-groups'] as List?)?.whereType<String>() ?? const <String>[]) {
      final mapped = retarget(g, teamID);
      if (allowed(mapped, allowedGroups) && !groups.contains(mapped)) groups.add(mapped);
    }
    final own = '$teamID.$bundleID';
    if (!groups.contains(own) && allowed(own, allowedGroups)) groups.insert(0, own);
    result['keychain-access-groups'] = groups;

    final dropped = <String>[];
    for (final entry in original.entries) {
      if (identityKeys.contains(entry.key)) continue;
      final permitted = profile[entry.key];
      final merged = permitted == null ? null : merge(entry.value, permitted);
      if (merged == null) {
        dropped.add(entry.key);
      } else {
        result[entry.key] = merged;
      }
    }
    dropped.sort();
    return (entitlements: result, dropped: dropped);
  }

  /// `ABCDE12345.group.x` → `TEAMID.group.x`. Значения без префикса команды не трогаем.
  static String retarget(String value, String teamID) {
    const placeholder = r'$(AppIdentifierPrefix)';
    if (value.startsWith(placeholder)) return '$teamID.${value.substring(placeholder.length)}';
    final dot = value.indexOf('.');
    if (dot < 0 || !isTeamID(value.substring(0, dot))) return value;
    return teamID + value.substring(dot);
  }

  static bool isTeamID(String s) => RegExp(r'^[A-Z0-9]{10}$').hasMatch(s);

  static bool allowed(String value, List<String> patterns) =>
      patterns.any((p) => p == '*' || p == value || (p.endsWith('*') && value.startsWith(p.substring(0, p.length - 1))));

  /// Значение исходного приложения в пределах разрешённого профилем.
  /// `*` в профиле — разрешено что угодно; список — пересечение; иначе — значение профиля
  /// (например, `aps-environment` = development вместо production).
  static dynamic merge(dynamic original, dynamic permitted) {
    if (permitted == '*') return original;
    if (permitted is List) {
      final list = permitted.whereType<String>().toList();
      if (list.contains('*')) return original;
      if (original is List) {
        final kept = original.whereType<String>().where((v) => allowed(v, list)).toList();
        return kept.isEmpty ? null : kept;
      }
      return list;
    }
    if (permitted is bool) return permitted ? original : null;
    return permitted;
  }
}
