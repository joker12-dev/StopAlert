import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../engine/segment_learner.dart';

/// Öğrenilen segment sürelerinin cihazdaki kalıcı deposu (SharedPreferences).
///
/// Hem UI (Riverpod) hem arka plan servisi (ayrı isolate) aynı anahtarı
/// okur/yazar; isolate Riverpod kullanamadığı için statik async API sunulur.
/// JSON şeması buluta anonim yüklemeye hazırdır (Faz 4 kalabalık öğrenme).
abstract final class SegmentLearningStore {
  static const _key = 'segment_learning_v1';

  /// Buluta gönderilmeyi bekleyen anonim gözlem kuyruğu. Arka plan servisi
  /// (Firebase'siz izolat) buraya yazar; ana izolat (Firebase'li) boşaltır.
  static const _queueKey = 'segment_cloud_queue';

  static Future<SegmentLearner> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return SegmentLearner();
    try {
      return SegmentLearner.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return SegmentLearner();
    }
  }

  static Future<void> save(SegmentLearner learner) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(learner.toJson()));
  }

  /// Yeni gözlemleri yükle → işle → kaydet (servis/isolate güvenli, atomik).
  /// Ayrıca bulut katkı kuyruğuna ekler (rıza varsa ana izolat gönderir).
  static Future<void> record(Iterable<SegmentObservation> observations) async {
    final list = observations.toList();
    if (list.isEmpty) return;
    final learner = await load();
    for (final o in list) {
      learner.observe(o.lineId, o.fromId, o.toId, o.seconds);
    }
    await save(learner);
    await _enqueueForCloud(list);
  }

  static Future<void> _enqueueForCloud(List<SegmentObservation> list) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_queueKey);
    final queue = <Map<String, dynamic>>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final e in jsonDecode(raw) as List) {
          queue.add(e as Map<String, dynamic>);
        }
      } catch (_) {}
    }
    for (final o in list) {
      queue.add({
        'lineId': o.lineId,
        'fromId': o.fromId,
        'toId': o.toId,
        's': o.seconds,
      });
    }
    // Kuyruğu makul bir sınırda tut (en yeni 500 gözlem).
    final trimmed =
        queue.length > 500 ? queue.sublist(queue.length - 500) : queue;
    await prefs.setString(_queueKey, jsonEncode(trimmed));
  }

  /// Bekleyen bulut kuyruğunu okur ve TEMİZLER (ana izolat gönderirken çağırır).
  static Future<List<SegmentObservation>> drainCloudQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_queueKey);
    if (raw == null || raw.isEmpty) return const [];
    await prefs.remove(_queueKey);
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          SegmentObservation(
            lineId: (e as Map<String, dynamic>)['lineId'] as String,
            fromId: e['fromId'] as String,
            toId: e['toId'] as String,
            seconds: (e['s'] as num).toDouble(),
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Kuyruğu göndermeden temizle (rıza yokken atmak için).
  static Future<void> clearCloudQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_queueKey);
  }
}

/// UI için: öğrenilmiş segment sayısı (ör. Ayarlar/Profil'de "X segment
/// öğrenildi" rozeti). Yolculuk bitince invalidate edilerek tazelenir.
final learnedSegmentCountProvider = FutureProvider<int>((ref) async {
  final learner = await SegmentLearningStore.load();
  return learner.learnedSegmentCount;
});
