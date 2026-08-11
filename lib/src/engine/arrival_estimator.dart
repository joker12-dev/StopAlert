import '../data/models.dart';
import '../data/timetable.dart';
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

  /// Bir aracın "aktif" sayılması için son konum yayınının azami yaşı.
  ///
  /// Servis, seferi bitmiş ya da garaja çekilmiş araçları listede
  /// bırakabiliyor. Üç dakikadır konum bildirmeyen otobüsü "yaklaşıyor"
  /// diye göstermek, gelmeyecek bir otobüsü beklettirmek olur.
  static const activeWithinSeconds = 180;

  /// Bayat konum düzeltmesinin üst sınırı (saniye).
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

    // Tazelik ÖLÇÜSÜ cihaz saati DEĞİL, aynı fotoğraftaki en yeni damga.
    //
    // Zaman damgaları İstanbul yerel saatinde geliyor; cihaz başka bir saat
    // diliminde ya da saati kaymışsa TÜM araçlar bayat görünür ve liste
    // bomboş kalırdı. Araçların hepsi aynı yayından geldiği için göreli
    // karşılaştırma saat diliminden bağımsızdır.
    final reference = _referenceTime(vehicles) ?? clock;

    final seconds = segmentSecondsFor(line);
    final out = <ArrivalEstimate>[];

    for (final v in vehicles) {
      final age = _ageSeconds(v, reference);
      // Uzun süredir konum bildirmeyen araç seferde değildir (garaja
      // çekilmiş, seferi bitmiş). Onu "yaklaşıyor" diye göstermek
      // gelmeyecek bir otobüsü beklettirmek olur.
      if (age != null && age > activeWithinSeconds) continue;
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

      // Yayından bu yana geçen sürede otobüs yol almaya devam etti.
      final staleness = (age ?? 0).clamp(0, _maxStalenessSeconds);
      eta -= staleness;
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

  /// Yayındaki EN YENİ zaman damgası — "şimdi"nin yerine geçer.
  /// Hiçbiri çözülemezse null.
  static DateTime? _referenceTime(List<BusVehicle> vehicles) {
    DateTime? newest;
    for (final v in vehicles) {
      final t = _parseSeen(v);
      if (t == null) continue;
      if (newest == null || t.isAfter(newest)) newest = t;
    }
    return newest;
  }

  /// Aracın konumunun [reference] anına göre yaşı (saniye).
  /// Damga okunamıyorsa null — o araç ne elenir ne düzeltilir.
  static int? _ageSeconds(BusVehicle v, DateTime reference) {
    final t = _parseSeen(v);
    if (t == null) return null;
    final d = reference.difference(t).inSeconds;
    return d < 0 ? 0 : d;
  }

  /// Biçim: "2026-08-06 22:38:57".
  static DateTime? _parseSeen(BusVehicle v) {
    final raw = v.lastSeen.trim();
    if (raw.isEmpty) return null;
    return DateTime.tryParse(raw.replaceFirst(' ', 'T'));
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

/// TARİFEYE dayalı varış — canlı araç konumu OLMAYAN şehirler için.
///
/// Kocaeli canlı araç konumu yayınlamıyor; elimizde yalnızca ilk duraktan
/// kalkış saatleri (pakete gömülü) ve duraklar arası süre var. Bir seferin
/// bu durağa ne zaman uğrayacağı = kalkış saati + ilk duraktan bu durağa
/// kadarki yol süresi.
///
/// Bu bir TAHMİN DEĞİL, PLANDIR: trafiği, gecikmeyi, seferin iptal edilip
/// edilmediğini bilmez. Kullanıcıya da böyle sunulmalı.
class ScheduledArrival {
  const ScheduledArrival({
    required this.at,
    required this.secondsAway,
    required this.departureTime,
  });

  /// Bu durağa planlanan varış anı.
  final DateTime at;

  /// Şu andan itibaren kaç saniye.
  final int secondsAway;

  /// Seferin ilk duraktan kalkış saati ("06:15") — kullanıcı tarifeyle
  /// eşleştirebilsin.
  final String departureTime;

  String get clockLabel {
    final h = at.hour.toString().padLeft(2, '0');
    final m = at.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String get awayLabel {
    final m = (secondsAway / 60).round();
    if (m <= 0) return 'şimdi';
    if (m < 60) return '$m dk';
    return '${m ~/ 60} sa ${m % 60} dk';
  }
}

extension ScheduledArrivals on ArrivalEstimator {
  /// Bir yön varyantının [departures] kalkışlarından, [targetStopId] durağına
  /// planlanan varışlar. [now]'dan sonrakiler, en yakından uzağa.
  static List<ScheduledArrival> fromSchedule({
    required TransitLine line,
    required String targetStopId,
    required List<Departure> departures,
    SegmentLearner? learner,
    DateTime? now,
    int limit = 3,
  }) {
    final clock = now ?? DateTime.now();
    final targetIndex = line.indexOfStop(targetStopId);
    // 0 = ilk durak: kalkış saatinin kendisi zaten varış saatidir, yol
    // süresi eklenmez. -1 = durak bu varyantta yok.
    if (targetIndex < 0) return const [];

    final seconds = ArrivalEstimator.segmentSecondsFor(line);
    final out = <ScheduledArrival>[];

    for (final d in departures) {
      final parts = d.time.split(':');
      if (parts.length < 2) continue;
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h == null || m == null) continue;

      // İKİ GÜN DENENİR. Gece seferleri 24'ü aşan saatle yazılıyor ("24:28" =
      // ertesi gün 00:28) ve saat 00:30'da bu sefer BUGÜNE aittir, yarına
      // değil — tek gün denemek onu 24 saat ileri atıyordu.
      // ÖNCE DÜNKÜ ÇAPA denenir: "24:28" bugünün 00:28'i demek ve saat
      // 00:20'de o sefer 8 dakika sonra kalkıyor. Bugünün çapasıyla başlamak
      // aynı seferi 24 saat ileriye atıyordu.
      DateTime? departAt;
      for (final dayShift in const [-1, 0]) {
        final candidate = DateTime(clock.year, clock.month, clock.day)
            .add(Duration(days: dayShift, hours: h, minutes: m));
        if (!candidate.isBefore(clock)) {
          departAt = candidate;
          break;
        }
      }
      if (departAt == null) continue;   // her iki gün de geçmişte

      // İlk duraktan hedefe yol süresi — öğrenilmiş süre varsa o kullanılır.
      var travel = 0.0;
      for (var i = 0; i < targetIndex; i++) {
        final at = departAt.add(Duration(seconds: travel.round()));
        final hit = learner?.lookup(
            line.id, line.stops[i].id, line.stops[i + 1].id, TimeBucket.of(at));
        travel += hit?.seconds ?? seconds[i];
      }

      final arriveAt = departAt.add(Duration(seconds: travel.round()));
      final away = arriveAt.difference(clock).inSeconds;
      // Geçmiş seferler atlanır; "kaçırdın" bilgisi burada işe yaramıyor.
      if (away < 0) continue;
      out.add(ScheduledArrival(
        at: arriveAt,
        secondsAway: away,
        departureTime: d.displayTime,
      ));
    }

    out.sort((a, b) => a.secondsAway.compareTo(b.secondsAway));
    return out.take(limit).toList();
  }
}
