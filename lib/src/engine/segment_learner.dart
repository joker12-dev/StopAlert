/// Yolculuklardan öğrenilen segment (durak→durak) geçiş süreleri modeli.
///
/// StopAlert "öğrenen uygulama" olsun diye: her tamamlanan yolculukta, GPS'in
/// iyi olduğu kısımlarda ölçülen gerçek durak-arası süreler bu modele işlenir.
/// Yeraltı (SINYAL_YOK) modunda ölü hesap ve varış tahminleri statik GTFS
/// süreleri yerine bu ÖĞRENİLMİŞ süreleri kullanır.
///
/// SÜRELER ZAMANA KOŞULLUDUR ([TimeBucket]): aynı segment akşam zirvesinde
/// gecenin iki katı sürebiliyor; tek ortalama ikisini de yanlış tahmin eder.
/// Model bu yüzden iki katmanlı: segment → kova → istatistik.
///
/// - Yerel önce: model cihazda tutulur (gizli, çevrimdışı, izin gerekmez).
/// - Kalabalık: aynı anahtarla buluta anonim toplanır; tek kullanıcı bir
///   segmenti ayda birkaç kez geçtiği için kovalar ancak birlikte dolar.
///
/// Segment anahtarı sıralı durak çiftidir: "lineId|fromStopId|toStopId" — yön
/// doğal olarak kodlanır (gidiş ve dönüş farklı süre öğrenir).
library;

import 'time_bucket.dart';

/// Zamanı bilinmeyen gözlemlerin kovası.
///
/// Sürüm yükseltmesinde eski (kovasız) kayıtlar buraya taşınır: veri atılmaz,
/// yalnızca "hangi saatte ölçüldüğü bilinmiyor" olarak işaretlenir ve
/// kovalı bir değer bulunamadığında yedek olarak kullanılır.
const String kUnknownBucket = '?';

/// Tamamlanan bir yolculuktan çıkan tek segment gözlemi (öğrenmeye beslenir).
class SegmentObservation {
  const SegmentObservation({
    required this.lineId,
    required this.fromId,
    required this.toId,
    required this.seconds,
    this.bucketCode = kUnknownBucket,
  });

  final String lineId;
  final String fromId;
  final String toId;
  final double seconds;

  /// Segmentin GEÇİLDİĞİ andaki zaman kovası ([TimeBucket.code]).
  final String bucketCode;
}

/// Tek bir segment + kova için öğrenilen istatistik.
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

/// Bir aramanın SONUCU: süre + nereden geldiği.
///
/// Kaynak, tahminin ne kadar güvenilir olduğunu belirler — ETA gösterirken
/// aralık genişliği buna göre ayarlanır.
enum LearnedSource {
  /// Tam bu gün tipi + saat bandı için ölçülmüş.
  exact,

  /// Aynı gün tipinde komşu bir saat bandından.
  neighbourBand,

  /// Başka gün tipinden ya da zamanı bilinmeyen eski kayıttan.
  fallback,
}

class LearnedTime {
  const LearnedTime(this.seconds, this.source, this.samples);

  final double seconds;
  final LearnedSource source;
  final int samples;
}

class SegmentLearner {
  SegmentLearner([Map<String, Map<String, SegmentStat>>? stats])
      : _stats = {
          for (final e in (stats ?? const <String, Map<String, SegmentStat>>{})
              .entries)
            e.key: {...e.value},
        };

  /// segmentKey → (kova kodu → istatistik)
  final Map<String, Map<String, SegmentStat>> _stats;

  /// Gözlem güvenilir sayılmadan (aykırı eleme devreye girmeden) önceki
  /// örnek sayısı.
  static const _minSamplesForClamp = 3;

  /// Fiziksel olarak makul segment süresi penceresi (saniye). Dışı gürültü.
  static const _minSeconds = 3.0;
  static const _maxSeconds = 1800.0; // 30 dk

  static String keyFor(String lineId, String fromId, String toId) =>
      '$lineId|$fromId|$toId';

  /// Öğrenilmiş SEGMENT sayısı (kova sayısı değil) — kullanıcıya gösterilen
  /// rozet bunu sayar; "3 segment öğrenildi" 15 kovadan daha anlamlı.
  int get learnedSegmentCount => _stats.length;

  /// Toplam kova sayısı (tanı amaçlı).
  int get learnedBucketCount =>
      _stats.values.fold(0, (sum, m) => sum + m.length);

  /// [bucket] için en iyi öğrenilmiş süre; hiç veri yoksa null.
  ///
  /// Arama sırası: tam kova → aynı gün tipinde komşu bant → zamanı bilinmeyen
  /// eski kayıt → o segmentin tüm kovalarının örnek-ağırlıklı ortalaması.
  /// Sıra bilinçli: yakın bir zaman diliminden gelen ölçü, başka bir güne ait
  /// ölçüden daha iyi bir tahmindir.
  LearnedTime? lookup(
    String lineId,
    String fromId,
    String toId,
    TimeBucket? bucket,
  ) {
    final buckets = _stats[keyFor(lineId, fromId, toId)];
    if (buckets == null || buckets.isEmpty) return null;

    if (bucket != null) {
      final exact = buckets[bucket.code];
      if (exact != null) {
        return LearnedTime(
            exact.meanSeconds, LearnedSource.exact, exact.samples);
      }
      for (final band in bucket.neighbours) {
        final s = buckets[TimeBucket(bucket.day, band).code];
        if (s != null) {
          return LearnedTime(
              s.meanSeconds, LearnedSource.neighbourBand, s.samples);
        }
      }
    }

    final legacy = buckets[kUnknownBucket];
    if (legacy != null) {
      return LearnedTime(
          legacy.meanSeconds, LearnedSource.fallback, legacy.samples);
    }

    // Son çare: tüm kovaların örnek-ağırlıklı ortalaması. Kaba ama statik
    // GTFS süresinden yine de iyi (o hattın gerçek temposunu taşır).
    var sum = 0.0;
    var n = 0;
    for (final s in buckets.values) {
      sum += s.meanSeconds * s.samples;
      n += s.samples;
    }
    if (n == 0) return null;
    return LearnedTime(sum / n, LearnedSource.fallback, n);
  }

  /// Öğrenilmiş süre (saniye, yuvarlanmış); henüz öğrenilmediyse null.
  int? learnedSeconds(
    String lineId,
    String fromId,
    String toId, {
    TimeBucket? bucket,
  }) =>
      lookup(lineId, fromId, toId, bucket)?.seconds.round();

  /// Bir gözlemi modele işler (EMA). Aykırı değerler (uzun bekleme, GPS
  /// sıçraması) yeterli örnek biriktiğinde ±3x'e kırpılarak modeli bozmaz.
  void observe(
    String lineId,
    String fromId,
    String toId,
    double seconds, {
    String bucketCode = kUnknownBucket,
    double alpha = 0.3,
  }) {
    if (seconds < _minSeconds || seconds > _maxSeconds) return;
    final key = keyFor(lineId, fromId, toId);
    final buckets = _stats.putIfAbsent(key, () => {});
    final cur = buckets[bucketCode];
    if (cur == null) {
      buckets[bucketCode] = SegmentStat(meanSeconds: seconds, samples: 1);
      return;
    }
    var obs = seconds;
    if (cur.samples >= _minSamplesForClamp) {
      obs = obs.clamp(cur.meanSeconds / 3, cur.meanSeconds * 3);
    }
    buckets[bucketCode] = SegmentStat(
      meanSeconds: alpha * obs + (1 - alpha) * cur.meanSeconds,
      samples: cur.samples + 1,
    );
  }

  /// Buluttaki (kalabalık) ortalamayı YALNIZCA o kovada kişisel veri yoksa
  /// tohumlar — kişisel öğrenme her zaman baskındır (yerel > kalabalık).
  void seedIfAbsent(
    String lineId,
    String fromId,
    String toId,
    double meanSeconds,
    int samples, {
    String bucketCode = kUnknownBucket,
  }) {
    if (meanSeconds < _minSeconds || meanSeconds > _maxSeconds) return;
    final buckets = _stats.putIfAbsent(keyFor(lineId, fromId, toId), () => {});
    if (buckets.containsKey(bucketCode)) return; // kişisel değer korunur
    buckets[bucketCode] = SegmentStat(
      meanSeconds: meanSeconds,
      samples: samples < 1 ? 1 : samples,
    );
  }

  Map<String, dynamic> toJson() => {
        for (final e in _stats.entries)
          e.key: {for (final b in e.value.entries) b.key: b.value.toJson()},
      };

  /// Eski (kovasız) şemayı da okur.
  ///
  /// v1 biçimi: `{"line|a|b": {"m": 120, "n": 4}}`
  /// v2 biçimi: `{"line|a|b": {"Im": {"m": 120, "n": 4}}}`
  /// Ayrım, değerin içinde `m` anahtarı olup olmamasına bakılarak yapılır.
  /// Eski kayıtlar ATILMAZ; "zamanı bilinmiyor" kovasına taşınır.
  factory SegmentLearner.fromJson(Map<String, dynamic> json) {
    final stats = <String, Map<String, SegmentStat>>{};
    for (final e in json.entries) {
      try {
        final v = e.value as Map<String, dynamic>;
        if (v.containsKey('m')) {
          stats[e.key] = {kUnknownBucket: SegmentStat.fromJson(v)};
          continue;
        }
        final buckets = <String, SegmentStat>{};
        for (final b in v.entries) {
          buckets[b.key] =
              SegmentStat.fromJson(b.value as Map<String, dynamic>);
        }
        if (buckets.isNotEmpty) stats[e.key] = buckets;
      } catch (_) {
        // Bozuk giriş: atla.
      }
    }
    return SegmentLearner(stats);
  }
}
