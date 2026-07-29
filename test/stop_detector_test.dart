import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/engine/stop_detector.dart';

/// Belirtilen sayıda örneği (100 ms arayla) besler; tespit edilen "durak
/// tamamlandı" olaylarının sayısını döndürür.
int _feedPhase(
  StopDetector d,
  List<double> pattern,
  int count,
  List<int> clock,
) {
  var events = 0;
  for (var i = 0; i < count; i++) {
    final mag = pattern[i % pattern.length];
    if (d.feed(mag, Duration(milliseconds: clock[0]))) events++;
    clock[0] += 100;
  }
  return events;
}

void main() {
  group('StopDetector', () {
    test('hareket → yeterli duruş → kalkış bir durak sayar', () {
      final d = StopDetector(minStopMs: 2000);
      final clock = [0];
      // Hareket (yüksek varyans) 2 sn.
      var events = _feedPhase(d, const [9.3, 10.3], 20, clock);
      expect(events, 0);
      expect(d.isStopped, isFalse);

      // Duruş (düşük varyans) 3 sn (> minStopMs).
      events += _feedPhase(d, const [9.805, 9.815], 30, clock);
      expect(d.isStopped, isTrue);
      expect(events, 0); // henüz kalkmadı

      // Yeniden hareket → kalkış → bir durak.
      events += _feedPhase(d, const [9.3, 10.3], 20, clock);
      expect(events, 1);
      expect(d.isStopped, isFalse);
    });

    test('kısa duruş (rulo/fren) durak saymaz', () {
      final d = StopDetector(minStopMs: 2000);
      final clock = [0];
      _feedPhase(d, const [9.3, 10.3], 20, clock);
      // Yalnızca 1 sn duruş (< minStopMs).
      _feedPhase(d, const [9.805, 9.815], 10, clock);
      final events = _feedPhase(d, const [9.3, 10.3], 20, clock);
      expect(events, 0);
    });

    test('duruş seviyesi öğrenilir (kalibre olur)', () {
      final d = StopDetector(minStopMs: 2000, initialStoppedVariance: 0.1);
      final clock = [0];
      _feedPhase(d, const [9.3, 10.3], 20, clock);
      _feedPhase(d, const [9.81, 9.81], 30, clock);
      // Duruşta gerçek varyans ~0 olduğundan öğrenilen duruş seviyesi düşer.
      expect(d.stoppedLevel, lessThan(0.1));
    });

    test('iki ardışık durak iki olay üretir', () {
      final d = StopDetector(minStopMs: 2000);
      final clock = [0];
      var events = 0;
      events += _feedPhase(d, const [9.3, 10.3], 20, clock); // hareket
      events += _feedPhase(d, const [9.805, 9.815], 30, clock); // duruş 1
      events += _feedPhase(d, const [9.3, 10.3], 20, clock); // kalkış -> +1
      events += _feedPhase(d, const [9.805, 9.815], 30, clock); // duruş 2
      events += _feedPhase(d, const [9.3, 10.3], 20, clock); // kalkış -> +1
      expect(events, 2);
    });
  });
}
