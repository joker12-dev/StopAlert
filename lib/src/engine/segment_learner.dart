/// Yolculuklardan öğrenilen segment (durak→durak) geçiş süreleri modeli.
///
/// StopAlert "öğrenen uygulama" olsun diye: her tamamlanan yolculukta, GPS'in
/// iyi olduğu kısımlarda ölçülen gerçek durak-arası süreler bu modele işlenir.
/// Yeraltı (SINYAL_YOK) modunda ölü hesap, statik GTFS süreleri yerine bu
/// ÖĞRENİLMİŞ süreleri kullanır — böylece tahmin kendi kendine iyileşir.
///
/// - Yerel önce: model cihazda tutulur (gizli, çevrimdışı, izin gerekmez).
/// - Buluta hazır: her giriş {lineId, fromId, toId, mean, samples} olarak
///   anonim toplanabilir (kalabalık öğrenme Faz 4'te aynı anahtarla açılır).
///
/// Anahtar sıralı durak çiftidir: "lineId|fromStopId|toStopId" — yön doğal
/// olarak kodlanır (gidiş ve dönüş farklı süre öğrenebilir).
library;

/// Tamamlanan bir yolculuktan çıkan tek segment gözlemi (öğrenmeye beslenir).
class SegmentObservation {
  const SegmentObservation({
    required this.lineId,
    required this.fromId,
    required this.toId,
    required this.seconds,
  });

  final String lineId;
  final String fromId;
  final String toId;
  final double seconds;
}

/// Tek bir segment için öğrenilen istatistik.
class SegmentStat {
  const SegmentStat({required this.meanSeconds, required this.samples});

  /// Üstel hareketli ortalama (EMA) ile güncellenen ortalama süre (saniye).
  final double meanSeconds;

  /// İşlenen gözlem sayısı — güven arttıkça büyür.
  final int samples;

  Map<String, dynamic> toJson() => {'m': meanSeconds, 'n': samples};

  factory SegmentStat.fromJson(Map<String, dynamic> j) => SegmentStat(
        meanSeconds: (j['m'] as num).toDouble(),
        samples: (j['n'] as num).toInt(),
      );
}

class SegmentLearner {
  SegmentLearner([Map<String, SegmentStat>? stats])
      : _stats = {...?stats};

  final Map<String, SegmentStat> _stats;

  /// Gözlem güvenilir sayılmadan (aykırı eleme devreye girmeden) önceki
  /// örnek sayısı.
  static const _minSamplesForClamp = 3;

  /// Fiziksel olarak makul segment süresi penceresi (saniye). Dışı gürültü.
  static const _minSeconds = 3.0;
  static const _maxSeconds = 1800.0; // 30 dk

  static String keyFor(String lineId, String fromId, String toId) =>
      '$lineId|$fromId|$toId';

  int get learnedSegmentCount => _stats.length;

  SegmentStat? statFor(String lineId, String fromId, String toId) =>
      _stats[keyFor(lineId, fromId, toId)];

  /// Öğrenilmiş süre (saniye, yuvarlanmış); henüz öğrenilmediyse null.
  int? learnedSeconds(String lineId, String fromId, String toId) =>
      _stats[keyFor(lineId, fromId, toId)]?.meanSeconds.round();

  /// Bir gözlemi modele işler (EMA). Aykırı değerler (uzun bekleme, GPS
  /// sıçraması) yeterli örnek biriktiğinde ±3x'e kırpılarak modeli bozmaz.
  void observe(
    String lineId,
    String fromId,
    String toId,
    double seconds, {
    double alpha = 0.3,
  }) {
    if (seconds < _minSeconds || seconds > _maxSeconds) return;
    final key = keyFor(lineId, fromId, toId);
    final cur = _stats[key];
    if (cur == null) {
      _stats[key] = SegmentStat(meanSeconds: seconds, samples: 1);
      return;
    }
    var obs = seconds;
    if (cur.samples >= _minSamplesForClamp) {
      final hi = cur.meanSeconds * 3;
      final lo = cur.meanSeconds / 3;
      obs = obs.clamp(lo, hi);
    }
    final mean = alpha * obs + (1 - alpha) * cur.meanSeconds;
    _stats[key] = SegmentStat(meanSeconds: mean, samples: cur.samples + 1);
  }

  /// Buluttaki (kalabalık) ortalama süreyi YALNIZCA kişisel veri yoksa
  /// tohumlar — kişisel öğrenme her zaman baskındır (hibrit: yerel > kalabalık).
  void seedIfAbsent(
    String lineId,
    String fromId,
    String toId,
    double meanSeconds,
    int samples,
  ) {
    if (meanSeconds < _minSeconds || meanSeconds > _maxSeconds) return;
    final key = keyFor(lineId, fromId, toId);
    if (_stats.containsKey(key)) return; // kişisel değer korunur
    _stats[key] = SegmentStat(
      meanSeconds: meanSeconds,
      samples: samples < 1 ? 1 : samples,
    );
  }

  Map<String, dynamic> toJson() =>
      {for (final e in _stats.entries) e.key: e.value.toJson()};

  factory SegmentLearner.fromJson(Map<String, dynamic> json) {
    final stats = <String, SegmentStat>{};
    for (final e in json.entries) {
      try {
        stats[e.key] = SegmentStat.fromJson(e.value as Map<String, dynamic>);
      } catch (_) {
        // Bozuk giriş: atla.
      }
    }
    return SegmentLearner(stats);
  }
}
