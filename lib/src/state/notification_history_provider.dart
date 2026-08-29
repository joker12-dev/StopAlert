import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Firebase Messaging ile gelen bir bildirimin GEÇMİŞ kaydı.
class NotifItem {
  const NotifItem({
    required this.id,
    required this.title,
    required this.body,
    required this.dateMs,
    required this.read,
  });

  final String id;
  final String title;
  final String body;
  final int dateMs;
  final bool read;

  DateTime get date => DateTime.fromMillisecondsSinceEpoch(dateMs);

  NotifItem copyWith({bool? read}) => NotifItem(
        id: id,
        title: title,
        body: body,
        dateMs: dateMs,
        read: read ?? this.read,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'date': dateMs,
        'read': read,
      };

  factory NotifItem.fromJson(Map<String, dynamic> m) => NotifItem(
        id: '${m['id'] ?? ''}',
        title: '${m['title'] ?? ''}',
        body: '${m['body'] ?? ''}',
        dateMs: (m['date'] as num?)?.toInt() ?? 0,
        read: m['read'] == true,
      );
}

/// Push bildirim geçmişinin KALICI deposu (shared_preferences).
///
/// Hem UI (provider) hem de ARKA PLAN isolate'i (onBackgroundMessage) buraya
/// yazar; bu yüzden Riverpod'dan bağımsız, düz statik bir API.
abstract final class NotificationHistoryStore {
  static const _key = 'push_history_v1';
  static const _cap = 50;

  static Future<List<NotifItem>> all() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return const [];
      final list = (jsonDecode(raw) as List)
          .map((e) => NotifItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList()
        ..sort((a, b) => b.dateMs.compareTo(a.dateMs));
      return list;
    } catch (_) {
      return const [];
    }
  }

  /// Yeni bildirimi başa ekler (aynı id varsa yeniler). En fazla [_cap] tutulur.
  static Future<void> add({
    required String title,
    required String body,
    String? id,
    int? dateMs,
  }) async {
    try {
      final p = await SharedPreferences.getInstance();
      final cur = await all();
      final now = dateMs ?? DateTime.now().millisecondsSinceEpoch;
      final item = NotifItem(
        id: (id == null || id.isEmpty) ? 'p$now' : id,
        title: title.trim().isEmpty ? 'Bildirim' : title.trim(),
        body: body.trim(),
        dateMs: now,
        read: false,
      );
      final next = <NotifItem>[
        item,
        for (final x in cur)
          if (x.id != item.id) x,
      ].take(_cap).toList();
      await p.setString(_key, jsonEncode([for (final x in next) x.toJson()]));
    } catch (_) {
      // Depoya yazılamadıysa sessiz geç: bildirim yine OS tarafından gösterilir.
    }
  }

  static Future<void> markAllRead() async {
    try {
      final p = await SharedPreferences.getInstance();
      final cur = await all();
      if (cur.every((x) => x.read)) return;
      final next = [for (final x in cur) x.copyWith(read: true)];
      await p.setString(_key, jsonEncode([for (final x in next) x.toJson()]));
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove(_key);
    } catch (_) {}
  }
}

/// Bildirim geçmişi — ekranlar bunu izler.
final notificationHistoryProvider =
    AsyncNotifierProvider<NotificationHistory, List<NotifItem>>(
        NotificationHistory.new);

class NotificationHistory extends AsyncNotifier<List<NotifItem>> {
  @override
  Future<List<NotifItem>> build() => NotificationHistoryStore.all();

  Future<void> refresh() async {
    state = AsyncData(await NotificationHistoryStore.all());
  }

  Future<void> markAllRead() async {
    await NotificationHistoryStore.markAllRead();
    await refresh();
  }

  Future<void> clear() async {
    await NotificationHistoryStore.clear();
    await refresh();
  }
}

/// Okunmamış push bildirim sayısı (zil rozeti + "tümünü okundu" için).
final unreadPushCountProvider = Provider<int>((ref) {
  final list = ref.watch(notificationHistoryProvider).valueOrNull ?? const [];
  return list.where((x) => !x.read).length;
});
