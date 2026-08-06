import '../data/models.dart';
import 'geo.dart';
import 'segment_learner.dart';

/// Yolculuğun anlık durumu (PLAN.md durum makinesi).
enum JourneyState {
  idle, // henüz başlamadı
  waiting, // BEKLEMEDE: kullanıcı hatta değil, binişe gidiyor
  active, // yolculuk sürüyor
  signalLost, // SINYAL_YOK: GPS kayboldu, zaman+ivmeölçer ile tahmin
  approaching, // alarm eşiği aşıldı — hazırlan/uyar
  arrived, // hedefe varıldı
}

/// Bir GPS örneği: konum + doğruluk + zaman.
class GpsSample {
  const GpsSample({
    required this.point,
    required this.accuracyMeters,
    required this.elapsed,
  });

  final LatLng point;
  final double accuracyMeters;

  /// Yolculuk başlangıcından bu örneğe kadar geçen süre.
  final Duration elapsed;
}

/// Motorun her güncellemede ürettiği anlık sonuç.
class JourneyStatus {
  const JourneyStatus({
    required this.state,
    required this.stopsRemaining,
    required this.distanceToTargetMeters,
    required this.nextStopName,
    required this.etaSeconds,
    required this.confidence,
  });

  final JourneyState state;
  final int stopsRemaining;
  final double distanceToTargetMeters;
  final String nextStopName;
  final int etaSeconds;

  /// 0..1 — tahmine güven (GPS'te hatta oturma; yeraltında belirsizlikle azalır).
  final double confidence;
}

/// Saf (yan etkisiz) yolculuk motoru.
///
/// GPS örneklerini tüketir, durum + kalan durak/mesafe/ETA üretir. Ayrıca
/// GPS kaybında ([updateNoSignal]) zaman + [onStopDetected] ivmeölçer
/// olaylarıyla ÖLÜ HESAP yapar; segment süreleri için önce ÖĞRENİLMİŞ
/// değerleri ([SegmentLearner]) kullanır. Tüm karar mantığı burada olduğundan
/// birim testleriyle sınanabilir (en kritik kod — PLAN.md).
class JourneyEngine {
  JourneyEngine({
    required TransitLine line,
    required String boardingStopId,
    required String targetStopId,
    this.alarmStopsThreshold = 2,
    this.alarmDistanceMeters = 500,
    this.arriveRadiusMeters = 120,
    this.armRadiusMeters = 250,
    SegmentLearner? learner,
  }) {
    _lineId = line.id;
    final a = line.indexOfStop(boardingStopId);
    final b = line.indexOfStop(targetStopId);
    assert(a != -1 && b != -1 && a != b);

    // Yolculuğu her zaman ileri yönde ele almak için biniş->iniş dilimini
    // (gerekirse ters çevirerek) çıkar.
    final forward = a < b;
    final slice = forward
        ? line.stops.sublist(a, b + 1)
        : line.stops.sublist(b, a + 1).reversed.toList();
    _routeStops = slice;
    _stopIds = [for (final s in slice) s.id];

    // Segment süreleri (saniye) aynı yönde hizalanır; öncelik: ÖĞRENİLMİŞ >
    // GTFS > varsayılan.
    final segs = line.segmentSeconds;
    List<int> base;
    if (segs != null && segs.length >= line.stops.length - 1) {
      final lo = forward ? a : b;
      final hi = forward ? b : a;
      final sub = segs.sublist(lo, hi);
      base = forward ? sub : sub.reversed.toList();
    } else {
      base = List.filled(slice.length - 1, line.defaultSegmentSeconds);
    }
    _segmentSeconds = [
      for (var i = 0; i < base.length; i++)
        learner?.learnedSeconds(_lineId, _stopIds[i], _stopIds[i + 1]) ??
            base[i],
    ];

    _points = [for (final s in slice) LatLng(s.lat, s.lon)];
    _segmentMeters = [
      for (var i = 0; i < _points.length - 1; i++)
        haversineMeters(_points[i], _points[i + 1]),
    ];

    // Kümülatif süre önekleri (ölü hesapta ilerleme→durak dönüşümü için).
    _cumSeconds = List.filled(_segmentSeconds.length + 1, 0);
    for (var i = 0; i < _segmentSeconds.length; i++) {
      _cumSeconds[i + 1] = _cumSeconds[i] + _segmentSeconds[i];
    }
  }

  final int alarmStopsThreshold;
  final double alarmDistanceMeters;
  final double arriveRadiusMeters;

  /// Hatta "binmiş" sayılmak için gereken azami hattan sapma (metre).
  final double armRadiusMeters;

  late final String _lineId;
  late final List<Stop> _routeStops;
  late final List<String> _stopIds;
  late final List<LatLng> _points;
  late final List<double> _segmentMeters;
  late final List<int> _segmentSeconds;
  late final List<int> _cumSeconds;

  JourneyState _state = JourneyState.idle;
  JourneyState get state => _state;

  /// Binişin algılandığı andaki yolculuk süresi (sn); null = henüz binilmedi.
  int? _activatedAtSeconds;

  /// Rota boyunca "program-zamanı" ilerleme (saniye): GPS varken izdüşümden
  /// tazelenir, GPS yokken saat + ivmeölçerle ilerletilir.
  double _progressSeconds = 0;

  /// En son işlenen örnekteki yolculuk süresi (delta hesabı için).
  int _lastElapsedSeconds = 0;

  /// SINYAL_YOK'ta biriken kör seyahat süresi (belirsizlik ölçüsü).
  double _signalLossSeconds = 0;

  /// İyi GPS altında bir durağın geçildiği an (öğrenme için): stopIndex→sn.
  final Map<int, int> _passElapsed = {};

  List<Stop> get routeStops => _routeStops;

  /// Emniyet kemeri: hattın toplam planlanan süresi (saniye).
  int get totalPlannedSeconds => _cumSeconds.last;

  /// SINYAL_YOK'ta ne kadar süredir kör seyahat edildiği (saniye).
  double get signalLossSeconds => _signalLossSeconds;

  // ---- Öğrenme çıktısı ----

  /// Tamamlanan yolculuktan, iyi GPS altında ölçülmüş segment gözlemleri.
  /// Depoya ([SegmentLearningStore]) beslenip model güncellenir.
  List<SegmentObservation> observations() {
    final out = <SegmentObservation>[];
    for (var i = 0; i < _stopIds.length - 1; i++) {
      final from = _passElapsed[i];
      final to = _passElapsed[i + 1];
      if (from == null || to == null) continue;
      final seconds = (to - from).toDouble();
      if (seconds <= 0) continue;
      out.add(SegmentObservation(
        lineId: _lineId,
        fromId: _stopIds[i],
        toId: _stopIds[i + 1],
        seconds: seconds,
      ));
    }
    return out;
  }

  // ---- GPS'li güncelleme ----

  /// Bir GPS örneğiyle durumu ilerletir ve anlık sonucu döndürür.
  JourneyStatus update(GpsSample sample) {
    final proj = projectOntoLine(sample.point, _points);
    final targetIndex = _points.length - 1;

    // BEKLEMEDE -> AKTİF geçişi.
    if (_state == JourneyState.idle || _state == JourneyState.waiting) {
      if (proj.offsetMeters <= armRadiusMeters) {
        _state = JourneyState.active;
        _activatedAtSeconds = sample.elapsed.inSeconds;
        _passElapsed[0] = sample.elapsed.inSeconds; // biniş anı
      } else {
        _state = JourneyState.waiting;
      }
    }

    // Durağa YETERİNCE yaklaştıysak o durağı geçilmiş say ve bir sonraki
    // segmentin başına normalize et.
    //
    // Eskiden oransal bir eşik vardı (t >= 0.999) ve gerçek hayatta tutmuyordu:
    // otobüs yolcuyu durak direğinin tam üstünde değil, 10–20 m önünde
    // bırakıyor. 600 m'lik bir segmentte 20 m eksik kalmak t = 0,967 eder;
    // durak "geçilmemiş" sayılır, kalan durak sayısı bir fazla görünür ve
    // yaklaşma alarmı geç çalardı. Ölçü artık METRE — segment uzunluğundan
    // bağımsız olarak aynı fiziksel tolerans.
    var segIndex = proj.segmentIndex;
    var t = proj.t;
    final metersToSegmentEnd = _segmentMeters[segIndex] * (1 - t);
    if (metersToSegmentEnd <= stopReachToleranceMeters &&
        segIndex < _segmentMeters.length - 1) {
      segIndex += 1;
      t = 0.0;
    }

    // Güven: hattan sapma + GPS doğruluğu.
    final noise = proj.offsetMeters + sample.accuracyMeters;
    final confidence = (1 - noise / 300).clamp(0.0, 1.0);

    // GPS geri geldi: belirsizliği sıfırla, "program-zamanı" ilerlemeyi
    // izdüşümden tazele (yeniden çapalama).
    if (_state == JourneyState.active ||
        _state == JourneyState.signalLost ||
        _state == JourneyState.approaching) {
      _progressSeconds = _cumSeconds[segIndex] + t * _segmentSeconds[segIndex];
      _signalLossSeconds = 0;
    }
    _lastElapsedSeconds = sample.elapsed.inSeconds;

    // İyi GPS altında durak geçişini öğrenme için kaydet.
    if (confidence >= 0.6 && proj.offsetMeters < 60) {
      _passElapsed.putIfAbsent(segIndex, () => sample.elapsed.inSeconds);
    }

    final atTarget = haversineMeters(sample.point, _points[targetIndex]) <=
        arriveRadiusMeters;

    if (_state == JourneyState.waiting) {
      final base = _composeStatus(segIndex, t);
      return JourneyStatus(
        state: _state,
        stopsRemaining: base.stopsRemaining.clamp(0, targetIndex + 1),
        distanceToTargetMeters: base.distance,
        nextStopName: _routeStops.first.name,
        etaSeconds: base.eta,
        confidence: confidence,
      );
    }

    final base = _composeStatus(segIndex, t);
    if (atTarget) {
      _state = JourneyState.arrived;
      // Son durağın geçiş anını da öğrenmeye kaydet (son segment için gerekli).
      _passElapsed.putIfAbsent(targetIndex, () => sample.elapsed.inSeconds);
      return _arrivedStatus(confidence);
    } else if (_isApproaching(base.stopsRemaining, base.distance,
        signalLost: false)) {
      _state = JourneyState.approaching;
    } else {
      _state = JourneyState.active;
    }
    return JourneyStatus(
      state: _state,
      stopsRemaining: base.stopsRemaining.clamp(0, targetIndex + 1),
      distanceToTargetMeters: base.distance,
      nextStopName: _routeStops[base.nextStopIndex].name,
      etaSeconds: base.eta,
      confidence: confidence,
    );
  }

  // ---- GPS'siz (yeraltı) ölü hesap ----

  /// GPS yokken çağrılır: "program-zamanı" ilerlemeyi geçen gerçek süreyle
  /// ilerletir, belirsizliği biriktirir ve SINYAL_YOK durumunu üretir.
  ///
  /// Biniş algılanmadıysa (henüz BEKLEMEDE) ölü hesap yapmaz.
  JourneyStatus updateNoSignal(Duration elapsed) {
    if (_activatedAtSeconds == null) {
      // Henüz hatta binilmedi: bekleme durumu.
      final base = _composeStatus(0, 0);
      return JourneyStatus(
        state: JourneyState.waiting,
        stopsRemaining: base.stopsRemaining,
        distanceToTargetMeters: base.distance,
        nextStopName: _routeStops.first.name,
        etaSeconds: base.eta,
        confidence: 0.2,
      );
    }
    if (_state == JourneyState.arrived) return _arrivedStatus(0.3);

    final now = elapsed.inSeconds;
    final delta = (now - _lastElapsedSeconds).clamp(0, 600).toDouble();
    _lastElapsedSeconds = now;
    _progressSeconds =
        (_progressSeconds + delta).clamp(0, totalPlannedSeconds.toDouble());
    _signalLossSeconds += delta;

    return _statusFromProgress(fromSignalLoss: true);
  }

  /// İvmeölçer bir DURAK durması tespit etti: ilerlemeyi bir sonraki durak
  /// sınırına ilerlet (durak sayımı). "Sinyal beklemesi" filtresi: mevcut
  /// segmentin en az [minSegmentFractionForStop]'i geçilmeden gelen durma
  /// büyük olasılıkla trafik/sinyal beklemesidir, sayılmaz.
  ///
  /// Yalnızca SINYAL_YOK'ta anlamlıdır (GPS varken izdüşüm zaten çapalar).
  /// Füzyon "temkinli kazanır": ilerleme yalnızca İLERİ gider (max), böylece
  /// saat ve sayaç tahminlerinden hedefe daha yakın olan baskındır.
  JourneyStatus onStopDetected(Duration elapsed) {
    if (_activatedAtSeconds == null || _state == JourneyState.arrived) {
      return _statusFromProgress(fromSignalLoss: _state == JourneyState.signalLost);
    }
    // Önce saatle ilerlemeyi güncelle.
    updateNoSignal(elapsed);

    final seg = _segmentForProgress(_progressSeconds);
    final segStart = _cumSeconds[seg].toDouble();
    final segDur = _segmentSeconds[seg].toDouble();
    final fraction = segDur <= 0 ? 1.0 : (_progressSeconds - segStart) / segDur;

    // Sinyal beklemesi filtresi.
    if (fraction < minSegmentFractionForStop) {
      return _statusFromProgress(fromSignalLoss: true);
    }

    // Bir sonraki durak sınırına ilerlet (yalnızca ileri).
    final nextBoundary = _cumSeconds[(seg + 1).clamp(0, _cumSeconds.length - 1)]
        .toDouble();
    if (nextBoundary > _progressSeconds) {
      _progressSeconds = nextBoundary.clamp(0, totalPlannedSeconds.toDouble());
    }
    return _statusFromProgress(fromSignalLoss: true);
  }

  /// Sinyal beklemesi eşiği: segmentin bu oranı geçilmeden gelen durma sayılmaz.
  static const double minSegmentFractionForStop = 0.45;

  /// Bir durağa bu kadar kala durak GEÇİLMİŞ sayılır (metre).
  ///
  /// Otobüs yolcuyu durak direğinin tam üstünde bırakmıyor; 10–20 m öncesinde
  /// ya da sonrasında duruyor, üstelik şehir içi GPS'in kendi hatası da bu
  /// mertebede. 25 m, gerçek durma noktalarını kapsayacak kadar geniş ama
  /// duraklar arası en kısa mesafeden (şehir içinde ~200 m) belirgin küçük —
  /// yani bir sonraki durağı erken saymaz.
  static const double stopReachToleranceMeters = 25;

  JourneyStatus _statusFromProgress({required bool fromSignalLoss}) {
    final seg = _segmentForProgress(_progressSeconds);
    final segDur = _segmentSeconds[seg].toDouble();
    final t = segDur <= 0
        ? 0.0
        : ((_progressSeconds - _cumSeconds[seg]) / segDur).clamp(0.0, 1.0);
    final base = _composeStatus(seg, t);

    // Varış: ilerleme toplam süreye ulaştı.
    if (_progressSeconds >= totalPlannedSeconds - 1) {
      _state = JourneyState.arrived;
      return _arrivedStatus(0.4);
    }

    // Belirsizlikle azalan güven.
    final confidence = (0.6 - _signalLossSeconds / 1200).clamp(0.1, 0.6);

    if (_isApproaching(base.stopsRemaining, base.distance, signalLost: true)) {
      _state = JourneyState.approaching;
    } else {
      _state = fromSignalLoss ? JourneyState.signalLost : JourneyState.active;
    }
    return JourneyStatus(
      state: _state,
      stopsRemaining: base.stopsRemaining,
      distanceToTargetMeters: base.distance,
      nextStopName: _routeStops[base.nextStopIndex].name,
      etaSeconds: base.eta,
      confidence: confidence,
    );
  }

  // ---- Ortak yardımcılar ----

  int _segmentForProgress(double progress) {
    var seg = 0;
    while (seg < _segmentSeconds.length - 1 && progress >= _cumSeconds[seg + 1]) {
      seg++;
    }
    return seg;
  }

  ({int stopsRemaining, double distance, int eta, int nextStopIndex})
      _composeStatus(int seg, double t) {
    final targetIndex = _points.length - 1;
    final nextStopIndex = (seg + 1).clamp(0, targetIndex);
    var distance = _segmentMeters[seg] * (1 - t);
    for (var i = seg + 1; i < _segmentMeters.length; i++) {
      distance += _segmentMeters[i];
    }
    var eta = (_segmentSeconds[seg] * (1 - t)).round();
    for (var i = seg + 1; i < _segmentSeconds.length; i++) {
      eta += _segmentSeconds[i];
    }
    final stopsRemaining = targetIndex - nextStopIndex + 1;
    return (
      stopsRemaining: stopsRemaining,
      distance: distance,
      eta: eta,
      nextStopIndex: nextStopIndex,
    );
  }

  JourneyStatus _arrivedStatus(double confidence) => JourneyStatus(
        state: JourneyState.arrived,
        stopsRemaining: 0,
        distanceToTargetMeters: 0,
        nextStopName: _routeStops.last.name,
        etaSeconds: 0,
        confidence: confidence,
      );

  /// Yaklaşma kararı. SINYAL_YOK'ta belirsizlik arttıkça eşiği ÖNE çeker
  /// (daha erken uyarı): her ~3 dk kör seyahat için bir durak marj, ayrıca
  /// son durakta (kalan ≤ 1) her koşulda uyarır.
  bool _isApproaching(int stopsRemaining, double distance,
      {required bool signalLost}) {
    if (!signalLost) {
      return (alarmStopsThreshold > 0 &&
              stopsRemaining <= alarmStopsThreshold) ||
          (alarmDistanceMeters > 0 && distance <= alarmDistanceMeters);
    }
    // Yeraltı: belirsizlik biriktikçe eşiği ÖNE çek — ama kullanıcının SEÇTİĞİ
    // moda sadık kal ve marjı ÖLÇÜLÜ tut (250 m seçen kullanıcı 600 m'de alarm
    // istemez). Mesafe modunda durak-tabanlı yedeğe DÜŞME; yalnızca eşiği
    // en fazla ~%50 genişlet (her ~3 dk kör seyahat için +%25, tavan 2 kademe).
    final extra = (_signalLossSeconds / 180).floor().clamp(0, 2);
    if (alarmStopsThreshold > 0) {
      return stopsRemaining <= alarmStopsThreshold + extra;
    }
    if (alarmDistanceMeters > 0) {
      final effDist = alarmDistanceMeters * (1 + 0.25 * extra);
      return distance <= effDist;
    }
    // İki eşik de kapalıysa (teorik): son durakta uyar.
    return stopsRemaining <= 1;
  }

  /// Emniyet kemeri kontrolü: GPS tamamen ölse bile, planlanan sürenin
  /// [marginSeconds] öncesine gelindiyse alarmı zorla (ağdan bağımsız).
  bool shouldForceAlarm(int elapsedSeconds, {int marginSeconds = 60}) {
    if (_state == JourneyState.arrived) return false;
    final activatedAt = _activatedAtSeconds;
    if (activatedAt == null) return false;
    return elapsedSeconds - activatedAt >= totalPlannedSeconds - marginSeconds;
  }
}
