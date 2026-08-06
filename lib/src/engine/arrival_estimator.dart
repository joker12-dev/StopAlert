import '../data/models.dart';
import '../data/transit_db.dart';
import '../services/iett_service.dart';
import 'geo.dart';
import 'segment_learner.dart';
import 'time_bucket.dart';

/// Bir otobüsün belirli bir durağa tahmini varışı.
class ArrivalEstimate {
  const ArrivalEstimate({
    required this.vehicle,
    required this.stopsAway,
    required this.seconds,
    required this.spreadSeconds,
    required this.quality,
  });

  final BusVehicle vehicle;

  /// Hedefe kaç durak kaldı (1 = sıradaki durak burası).
  final int stopsAway;

  /// Orta tahmin (saniye).
  final int seconds;

  /// Belirsizlik yarıçapı (saniye). Kullanıcıya tek sayı değil ARALIK
  /// gösterilir; 60 saniyede bir yayın yapan bir beslemeyle "3 dakika"
  /// demek olmayan bir kesinlik iddia etmektir.
  final int spreadSeconds;

  final ArrivalQuality quality;

  int get minSeconds => (seconds - spreadSeconds).clamp(0, 1 << 30);
  int get maxSeconds => seconds + spreadSeconds;

  /// "4-6 dk" / "şimdi" biçiminde kullanıcı metni.
  String get rangeLabel {
    final lo = (minSeconds / 60).floor();
    final hi = (maxSeconds / 60).ceil();
    if (hi <= 1) return 'şimdi';
    if (lo <= 0) return '<$hi dk';
    if (lo == hi) return '$lo dk';
    return '$lo-$hi dk';
  }
}

/// Tahminin neye dayandığı — güven göstergesi.
enum ArrivalQuality {
  /// Yolun tamamı için o saat dilimine ait ölçülmüş süre vardı.
  learned,

  /// Bir kısmı ölçülmüş, kalanı tarifeden.
  partial,

  /// Hiç ölçüm yok; yalnızca tarife/mesafe dağılımı.
  schedule,
}

/// Canlı araç konumlarından durak varış süresi hesaplar.
///
/// İETT hazır varış süresi YAYINLAMIYOR (yalnızca araç konumu veriyor), bu
/// yüzden sayı burada üretilir. Yöntem:
///
///   1. Aracın hattaki durak sırası bulunur (servisin verdiği `yakinDurakKodu`,
///      yoksa konumun güzergâha izdüşümü).
///   2. Oradan hedef durağa kadarki segment süreleri toplanır — öncelik
///      ÖĞRENİLMİŞ (ve o saat dilimine ait) süre, yoksa tarife.
///   3. Son konum yayınından bu yana geçen süre DÜŞÜLÜR: besleme ~60 saniyede
///      bir güncelleniyor ve o sırada otobüs yol almaya devam ediyor.
///
/// DURAK BEKLEME PAYI EKLENMEZ — bilerek. Tarife süremiz resmi uçtan uca
/// sefer süresinin segmentlere bölünmesiyle çıkıyor (bkz. tools/gtfs), yani
/// beklemeler zaten içinde. Öğrenilmiş süreler de duraktan durağa geçiş
/// ölçtüğü için beklemeyi içerir. Üstüne pay eklemek çift sayma olurdu.
abstract final class ArrivalEstimator {
  /// İETT konum yayın aralığı (saniye) — belirsizliğin TABANI.
  ///
  /// İki yayın arasında 40 km/s'teki otobüs ~660 m yol alır; bu sınır
  /// algoritmayla aşılamaz, yalnızca dürüstçe raporlanabilir.
  static const feedCadenceSeconds = 60;

  /// Ufuk büyüdükçe artan model hatası (oransal).
  static const _horizonErrorRatio = 0.12;

  /// Ölçüm yerine tarifeye dayanan tahmine eklenen belirsizlik (saniye).
  static const _scheduleExtraSpread = 45;

  /// Bayat konum düzeltmesinin üst sınırı (saniye).
  ///
  /// Zaman damgası İstanbul yerel saati; cihaz başka saat diliminde olursa
  /// fark saatlerce çıkabilir. Sınır, böyle bir durumda tahminin saçmalamasını
  /// engeller.
  static const _maxStalenessSeconds = 300;

  /// [line] yönündeki [vehicles] için [targetStopId] durağına varış tahminleri.
  /// Durağı geçmiş araçlar elenir; sonuç en yakın varıştan uzağa sıralıdır.
  static List<ArrivalEstimate> forStop({
    required TransitLine line,
    required String targetStopId,
    required List<BusVehicle> vehicles,
    SegmentLearner? learner,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final targetIndex = line.indexOfStop(targetStopId);
    if (targetIndex <= 0) return const [];

    final seconds = segmentSecondsFor(line);
    final out = <ArrivalEstimate>[];

    for (final v in vehicles) {
      final idx = _vehicleIndex(line, v);
      // Durağı geçmiş ya da yeri belirlenemeyen araç gösterilmez: "geçti"
      // bilgisini varış gibi sunmak kullanıcıyı boşuna bekletir.
      if (idx == null || idx >= targetIndex) continue;

      var eta = 0.0;
      var learnedSegments = 0;
      final total = targetIndex - idx;
      for (var i = idx; i < targetIndex; i++) {
        // Saat, tahmin ilerledikçe akar: 20 dakika sonra varacak bir otobüs
        // bant sınırını aşabilir ve o segment başka bir kovadan okunmalıdır.
        final at = clock.add(Duration(seconds: eta.round()));
        final hit = learner?.lookup(
            line.id, line.stops[i].id, line.stops[i + 1].id, TimeBucket.of(at));
        if (hit != null) {
          eta += hit.seconds;
          if (hit.source == LearnedSource.exact) learnedSegments++;
        } else {
          eta += seconds[i];
        }
      }

      eta -= _stalenessSeconds(v, clock);
      if (eta < 0) eta = 0;

      final quality = learnedSegments == total
          ? ArrivalQuality.learned
          : (learnedSegments > 0
              ? ArrivalQuality.partial
              : ArrivalQuality.schedule);

      var spread = feedCadenceSeconds + eta * _horizonErrorRatio;
      if (quality != ArrivalQuality.learned) spread += _scheduleExtraSpread;

      out.add(ArrivalEstimate(
        vehicle: v,
        stopsAway: total,
        seconds: eta.round(),
        spreadSeconds: spread.round(),
        quality: quality,
      ));
    }

    out.sort((a, b) => a.seconds.compareTo(b.seconds));
    return out;
  }

  /// Aracın hattaki durak sırası.
  ///
  /// Önce servisin verdiği en yakın durak kodu kullanılır — İETT bunu zaten
  /// hesaplayıp gönderiyor ve izdüşümden güvenilirdir (hat kendi üstünden
  /// geçtiğinde izdüşüm yanlış segmente oturabiliyor).
  static int? _vehicleIndex(TransitLine line, BusVehicle v) {
    final code = v.nearestStopCode.trim();
    if (code.isNotEmpty) {
      final i = line.indexOfStop('$kBusPrefix$code');
      if (i != -1) return i;
    }
    // Yedek: konumu güzergâha izdüşür.
    if (!v.lat.isFinite || !v.lon.isFinite) return null;
    final pts = [for (final s in line.stops) LatLng(s.lat, s.lon)];
    if (pts.length < 2) return null;
    final proj = projectOntoLine(LatLng(v.lat, v.lon), pts);
    // Hattan çok uzaktaki araç bu güzergâhta değildir (garaj seferi vb.).
    if (proj.offsetMeters > 400) return null;
    return proj.t >= 0.5 ? proj.segmentIndex + 1 : proj.segmentIndex;
  }

  /// Son konum yayınından bu yana geçen süre (saniye).
  ///
  /// Biçim: "2026-08-06 22:38:57" (İstanbul yerel saati). Çözülemezse 0
  /// döner — yanlış bir düzeltme yapmaktansa hiç yapmamak yeğdir.
  static double _stalenessSeconds(BusVehicle v, DateTime now) {
    final raw = v.lastSeen.trim();
    if (raw.isEmpty) return 0;
    final t = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
    if (t == null) return 0;
    final d = now.difference(t).inSeconds;
    if (d <= 0) return 0;
    return d > _maxStalenessSeconds ? _maxStalenessSeconds.toDouble() : d.toDouble();
  }

  /// Hattın segment süreleri — MESAFEYE göre dağıtılmış.
  ///
  /// Ham veride süre tüm segmentlere EŞİT bölünmüş (resmi sefer süresi ÷
  /// segment sayısı, bkz. tools/gtfs/fetch_official.py). Bu, 300 m'lik bir
  /// şehir içi segmentle 3 km'lik bir otoyol segmentine aynı süreyi veriyor.
  /// Toplam korunarak mesafeye göre yeniden dağıtmak, hiçbir yeni veri
  /// gerektirmeden tahmini belirgin düzeltir.
  ///
  /// Koordinat yoksa ya da toplam mesafe sıfırsa ham değerler döner.
  static List<int> segmentSecondsFor(TransitLine line) {
    final n = line.stops.length - 1;
    if (n <= 0) return const [];
    final base = line.segmentSeconds;
    final raw = [
      for (var i = 0; i < n; i++)
        (base != null && base.length > i) ? base[i] : line.defaultSegmentSeconds,
    ];

    final meters = <double>[];
    var totalMeters = 0.0;
    for (var i = 0; i < n; i++) {
      final a = line.stops[i];
      final b = line.stops[i + 1];
      final d = haversineMeters(LatLng(a.lat, a.lon), LatLng(b.lat, b.lon));
      meters.add(d);
      totalMeters += d;
    }
    if (totalMeters <= 0) return raw;

    final totalSeconds = raw.fold<int>(0, (s, x) => s + x);
    if (totalSeconds <= 0) return raw;

    return [
      for (var i = 0; i < n; i++)
        (totalSeconds * meters[i] / totalMeters)
            .round()
            // Uçlarda saçmalamasın: durak arası 15 sn'den kısa, 10 dk'dan
            // uzun sürmez.
            .clamp(15, 600),
    ];
  }
}
