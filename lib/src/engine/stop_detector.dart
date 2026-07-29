/// İvmeölçerden DURAK durması tespiti — saf (yan etkisiz) algoritma.
///
/// Telefon cepte/çantadayken aracın hareketi ivme büyüklüğünde titreşim/gürültü
/// üretir; araç durunca bu değişkenlik neredeyse yalnızca yerçekimine (sabit)
/// düşer. Algoritma kısa bir zaman penceresindeki VARYANSı izler:
///   yüksek varyans = hareket,  düşük varyans = duruş.
/// Duruş→hareket geçişinde (kalkış) bir "durak tamamlandı" olayı üretir.
///
/// ÖĞRENME: hareket ve duruş varyans seviyeleri EMA ile sürekli öğrenilir;
/// eşikler bu öğrenilen seviyelerden türetilir — böylece dedektör cihaza ve
/// telefonun konumuna (cep/çanta/el) kendini kalibre eder.
///
/// "Sinyal beklemesi" (trafik/kısa rulo duruş) elemesi iki katmanlıdır:
/// burada [minStopMs] altı duruşlar sayılmaz; ayrıca [JourneyEngine] konuma
/// göre (segmentin yeterince geçilmemesi) ikinci bir filtre uygular.
class StopDetector {
  StopDetector({
    this.windowMs = 1000,
    this.minStopMs = 3000,
    this.minSamples = 4,
    double initialMovingVariance = 0.4,
    double initialStoppedVariance = 0.02,
  })  : _movingLevel = initialMovingVariance,
        _stoppedLevel = initialStoppedVariance;

  /// Varyans penceresi (ms).
  final int windowMs;

  /// Bir duruşun "durak" sayılması için gereken en az duruş süresi (ms) —
  /// anlık rulo/fren duruşlarını eler.
  final int minStopMs;

  /// Karar vermeden önce pencerede gereken en az örnek.
  final int minSamples;

  final List<({int ms, double mag})> _samples = [];

  double _movingLevel; // öğrenilen: hareket varyansı
  double _stoppedLevel; // öğrenilen: duruş varyansı
  bool _stopped = false;
  int? _stoppedSinceMs;

  bool get isStopped => _stopped;
  double get movingLevel => _movingLevel;
  double get stoppedLevel => _stoppedLevel;

  double _variance() {
    if (_samples.length < 2) return _movingLevel;
    var sum = 0.0;
    for (final s in _samples) {
      sum += s.mag;
    }
    final mean = sum / _samples.length;
    var v = 0.0;
    for (final s in _samples) {
      final d = s.mag - mean;
      v += d * d;
    }
    return v / _samples.length;
  }

  /// Bir ivme büyüklüğü örneği besle (magnitude = sqrt(x²+y²+z²)).
  /// Bir DURAK tamamlandıysa (duruş→kalkış) true döner.
  bool feed(double magnitude, Duration t) {
    final ms = t.inMilliseconds;
    _samples.add((ms: ms, mag: magnitude));
    while (_samples.isNotEmpty && ms - _samples.first.ms > windowMs) {
      _samples.removeAt(0);
    }
    if (_samples.length < minSamples) return false;

    final variance = _variance();
    final span =
        (_movingLevel - _stoppedLevel).abs().clamp(1e-4, double.infinity);
    final stopThreshold = _stoppedLevel + span * 0.35;
    final moveThreshold = _stoppedLevel + span * 0.6;

    var departed = false;
    if (!_stopped) {
      // Hareketliyken hareket seviyesini öğren.
      _movingLevel = 0.05 * variance + 0.95 * _movingLevel;
      if (variance < stopThreshold) {
        _stopped = true;
        _stoppedSinceMs = ms;
      }
    } else {
      // Durgunken duruş seviyesini öğren.
      _stoppedLevel = 0.1 * variance + 0.9 * _stoppedLevel;
      if (variance > moveThreshold) {
        final since = _stoppedSinceMs;
        final dwelled = since != null && (ms - since) >= minStopMs;
        _stopped = false;
        _stoppedSinceMs = null;
        departed = dwelled; // yeterince durduysak: bir durak tamamlandı
      }
    }
    return departed;
  }
}
