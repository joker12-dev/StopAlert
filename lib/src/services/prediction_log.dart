import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tahmin ↔ gerçek karşılaştırma defteri.
///
/// NEDEN: doğruluk ölçülmeden iyileştirilemez. Bir yolculuk başlarken motorun
/// verdiği "kalan süre" ile o yolculuğun GERÇEK süresi kaydedilmezse, model
/// değişikliklerinin işe yarayıp yaramadığı yalnızca tahmin edilebilir.
/// Burada tutulan kayıt, ileride sapma düzeltmesinin (hat × saat dilimi
/// bazında sistematik kayma) girdisi olacak.
///
/// TAMAMEN CİHAZDA: hiçbir şey gönderilmez, kullanıcıya Ayarlar'da özet
/// olarak gösterilir. Kayıt sayısı sınırlıdır (son 100 yolculuk).
class PredictionRecord {
  const PredictionRecord({
    required this.lineCode,
    required this.bucketCode,
    required this.predictedSeconds,
    required this.actualSeconds,
    required this.at,
  });

  final String lineCode;

  /// Yolculuğun başladığı zaman kovası ([TimeBucket.code]).
  final String bucketCode;

  /// Yolculuk başlarken tahmin edilen kalan süre.
  final int predictedSeconds;

  /// Gerçekleşen süre.
  final int actualSeconds;

  final DateTime at;

  /// Hata (saniye). Pozitif = TAHMİN KISA kaldı (otobüs geç geldi).
  int get errorSeconds => actualSeconds - predictedSeconds;

  Map<String, dynamic> toMap() => {
        'l': lineCode,
        'b': bucketCode,
        'p': predictedSeconds,
        'a': actualSeconds,
        't': at.millisecondsSinceEpoch,
      };

  factory PredictionRecord.fromMap(Map<String, dynamic> m) => PredictionRecord(
        lineCode: m['l'] as String? ?? '',
        bucketCode: m['b'] as String? ?? '?',
        predictedSeconds: (m['p'] as num?)?.toInt() ?? 0,
        actualSeconds: (m['a'] as num?)?.toInt() ?? 0,
        at: DateTime.fromMillisecondsSinceEpoch((m['t'] as num?)?.toInt() ?? 0),
      );
}

/// Tahmin doğruluğu özeti.
class PredictionAccuracy {
  const PredictionAccuracy({
    required this.samples,
    required this.meanAbsErrorSeconds,
    required this.meanBiasSeconds,
  });

  final int samples;

  /// Ortalama MUTLAK hata — "ne kadar şaşırıyoruz".
  final double meanAbsErrorSeconds;

  /// Ortalama İŞARETLİ hata — "hangi yöne şaşırıyoruz".
  /// Pozitif: sistematik olarak kısa tahmin ediyoruz (otobüs geç geliyor).
  final double meanBiasSeconds;

  static const empty =
      PredictionAccuracy(samples: 0, meanAbsErrorSeconds: 0, meanBiasSeconds: 0);
}

abstract final class PredictionLog {
  static const _key = 'prediction_log_v1';
  static const _maxRecords = 100;

  static Future<void> record(PredictionRecord r) async {
    // Anlamsız kayıtları alma: sıfır/negatif süre ölçüm değil, gürültüdür.
    if (r.predictedSeconds <= 0 || r.actualSeconds <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final list = await load();
    final next = [...list, r];
    final trimmed = next.length > _maxRecords
        ? next.sublist(next.length - _maxRecords)
        : next;
    await prefs.setString(
      _key,
      jsonEncode([for (final e in trimmed) e.toMap()]),
    );
  }

  static Future<List<PredictionRecord>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          PredictionRecord.fromMap(e as Map<String, dynamic>),
      ];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// Kayıtlardan doğruluk özeti. [bucketCode] verilirse yalnızca o zaman
  /// dilimi — sapma saat dilimine göre değişiyor, bu yüzden ayrı bakılır.
  static PredictionAccuracy summarize(
    List<PredictionRecord> records, {
    String? bucketCode,
    String? lineCode,
  }) {
    final rows = [
      for (final r in records)
        if ((bucketCode == null || r.bucketCode == bucketCode) &&
            (lineCode == null || r.lineCode == lineCode))
          r,
    ];
    if (rows.isEmpty) return PredictionAccuracy.empty;
    var absSum = 0.0;
    var sum = 0.0;
    for (final r in rows) {
      absSum += r.errorSeconds.abs();
      sum += r.errorSeconds;
    }
    return PredictionAccuracy(
      samples: rows.length,
      meanAbsErrorSeconds: absSum / rows.length,
      meanBiasSeconds: sum / rows.length,
    );
  }
}

/// Ayarlar'daki "tahmin doğruluğu" satırı bunu okur.
final predictionAccuracyProvider =
    FutureProvider<PredictionAccuracy>((ref) async {
  return PredictionLog.summarize(await PredictionLog.load());
});
