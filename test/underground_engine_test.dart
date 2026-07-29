import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/data/models.dart';
import 'package:stopalert/src/engine/geo.dart';
import 'package:stopalert/src/engine/journey_engine.dart';
import 'package:stopalert/src/engine/segment_learner.dart';

/// Test hattı: 5 durak, ~1 km aralıklı, düz doğu-batı; her segment 120 sn.
TransitLine _testLine() {
  const lat = 41.0;
  return TransitLine(
    id: 'TEST',
    code: 'T',
    name: 'Test Hattı',
    type: LineType.metro,
    segmentSeconds: const [120, 120, 120, 120],
    stops: const [
      Stop(id: 's0', name: 'Durak 0', lat: lat, lon: 29.000),
      Stop(id: 's1', name: 'Durak 1', lat: lat, lon: 29.012),
      Stop(id: 's2', name: 'Durak 2', lat: lat, lon: 29.024),
      Stop(id: 's3', name: 'Durak 3', lat: lat, lon: 29.036),
      Stop(id: 's4', name: 'Durak 4', lat: lat, lon: 29.048),
    ],
  );
}

GpsSample _at(double lon, int elapsedSec, {double acc = 8}) => GpsSample(
      point: LatLng(41.0, lon),
      accuracyMeters: acc,
      elapsed: Duration(seconds: elapsedSec),
    );

void main() {
  group('Öğrenilen segment süresi kullanımı', () {
    test('öğrenilmiş süre GTFS yerine geçer (ETA/toplam süre)', () {
      final line = _testLine();
      final learner = SegmentLearner()
        ..observe('TEST', 's0', 's1', 200); // GTFS 120 -> öğrenilmiş 200
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
        learner: learner,
      );
      // 200 + 120 + 120 + 120 = 560
      expect(engine.totalPlannedSeconds, 560);
    });
  });

  group('SINYAL_YOK ölü hesap', () {
    test('GPS kaybında zaman ilerledikçe durak azalır, sonunda varır', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
        alarmStopsThreshold: 1,
      );
      // Binişte GPS ile aktifleş.
      engine.update(_at(29.000, 0));
      expect(engine.state, JourneyState.active);

      // 180 sn kör seyahat: ilerleme ~1.5 segment (seg1 ortası) -> 3 durak.
      var st = engine.updateNoSignal(const Duration(seconds: 180));
      expect(st.state, JourneyState.signalLost);
      expect(st.stopsRemaining, 3);

      // Toplam planlı süre (480 sn) dolunca varış.
      st = engine.updateNoSignal(const Duration(seconds: 480));
      expect(st.state, JourneyState.arrived);
      expect(st.stopsRemaining, 0);
    });

    test('MESAFE modunda uzaktayken erken çalmaz (250m ≠ 3km bug)', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
        alarmDistanceMeters: 250,
        alarmStopsThreshold: 0,
      );
      engine.update(_at(29.000, 0)); // binişte aktifleş
      // 60 sn kör: hedefe ~3.5 km var; 250 m modunda ALARM ÇALMAMALI.
      var st = engine.updateNoSignal(const Duration(seconds: 60));
      expect(st.state, JourneyState.signalLost);
      expect(st.distanceToTargetMeters, greaterThan(1000));
      // Hedefe ~250 m kalınca (son segmentin sonu) çalar.
      st = engine.updateNoSignal(const Duration(seconds: 450));
      expect(st.state, JourneyState.approaching);
    });

    test('belirsizlik arttıkça alarm eşiği öne çekilir', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
        alarmStopsThreshold: 1,
        alarmDistanceMeters: 0,
      );
      engine.update(_at(29.000, 0));
      // 250 sn kör: 2 durak kaldı; normalde eşik 1 iken belirsizlik marjıyla
      // (250/180 -> +1) yaklaşma tetiklenir.
      final st = engine.updateNoSignal(const Duration(seconds: 250));
      expect(st.stopsRemaining, 2);
      expect(st.state, JourneyState.approaching);
    });
  });

  group('İvmeölçer durak sayımı + sinyal beklemesi filtresi', () {
    test('segment ortasında tespit durağı ilerletir', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
        alarmDistanceMeters: 0,
      );
      engine.update(_at(29.000, 0));
      engine.updateNoSignal(const Duration(seconds: 60)); // seg0 t=0.5
      // fraction 0.5 >= 0.45 -> sonraki durak sınırına ilerlet.
      final st = engine.onStopDetected(const Duration(seconds: 60));
      // sınır cum[1]=120 -> seg1 başı, 3 durak kaldı.
      expect(st.stopsRemaining, 3);
    });

    test('erken (sinyal beklemesi) duruş sayılmaz', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
        alarmDistanceMeters: 0,
      );
      engine.update(_at(29.000, 0));
      engine.updateNoSignal(const Duration(seconds: 30)); // seg0 t=0.25
      final st = engine.onStopDetected(const Duration(seconds: 30));
      // fraction 0.25 < 0.45 -> yok sayılır, ilerleme değişmez (4 durak).
      expect(st.stopsRemaining, 4);
    });
  });

  group('GPS geri gelince yeniden çapalama', () {
    test('ölü hesap sürüklenmesi GPS ile düzeltilir', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
        alarmStopsThreshold: 1,
      );
      engine.update(_at(29.000, 0));
      // Kör seyahatte ilerleme birikti.
      engine.updateNoSignal(const Duration(seconds: 300));
      expect(engine.signalLossSeconds, greaterThan(0));
      // GPS geri geldi: gerçekte hâlâ 1. durak civarındayız.
      final st = engine.update(_at(29.012, 320));
      expect(engine.signalLossSeconds, 0);
      expect(st.state, isNot(JourneyState.signalLost));
      // Konum s1'de -> 3 durak kaldı (ölü hesabın söylediği değil).
      expect(st.stopsRemaining, 3);
    });
  });

  group('Öğrenme çıktısı (segment gözlemleri)', () {
    test('iyi GPS altında geçilen her segment ölçülür', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
      );
      // Her durağı 130 sn arayla geç (gerçek süre GTFS'ten farklı).
      engine.update(_at(29.000, 0));
      engine.update(_at(29.012, 130));
      engine.update(_at(29.024, 260));
      engine.update(_at(29.036, 390));
      engine.update(_at(29.048, 520));

      final obs = engine.observations();
      expect(obs.length, 4);
      expect(obs.first.fromId, 's0');
      expect(obs.first.toId, 's1');
      for (final o in obs) {
        expect(o.seconds, closeTo(130, 1));
      }
    });
  });
}
