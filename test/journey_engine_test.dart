import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/data/models.dart';
import 'package:stopalert/src/engine/geo.dart';
import 'package:stopalert/src/engine/journey_engine.dart';

/// Test hattı: 5 durak, ~1 km aralıklı, düz bir doğu-batı çizgisi.
/// Boylamda 0.012 derece ≈ enlem 41'de ~1 km.
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

void main() {
  group('geo', () {
    test('haversine ~1 km segmenti doğru ölçer', () {
      final d = haversineMeters(
        const LatLng(41.0, 29.000),
        const LatLng(41.0, 29.012),
      );
      expect(d, closeTo(1000, 120));
    });

    test('projeksiyon en yakın segmenti ve oranı bulur', () {
      final line = _testLine();
      final pts = [for (final s in line.stops) LatLng(s.lat, s.lon)];
      // Durak 1 ile 2 arasının ortası, hafif kuzeye kaymış.
      final proj = projectOntoLine(const LatLng(41.0005, 29.018), pts);
      expect(proj.segmentIndex, 1);
      expect(proj.t, closeTo(0.5, 0.1));
      expect(proj.offsetMeters, lessThan(100));
    });
  });

  group('JourneyEngine ileri yön', () {
    test('başta aktif, hedefe yaklaşınca approaching, varınca arrived', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
        alarmStopsThreshold: 1,
      );

      // Durak 0'da: 4 durak kaldı, aktif.
      var st = engine.update(const GpsSample(
        point: LatLng(41.0, 29.000),
        accuracyMeters: 10,
        elapsed: Duration.zero,
      ));
      expect(st.state, JourneyState.active);
      expect(st.stopsRemaining, 4);
      expect(st.nextStopName, 'Durak 1');

      // Durak 3'te: 1 durak kaldı -> eşik 1, approaching.
      st = engine.update(const GpsSample(
        point: LatLng(41.0, 29.036),
        accuracyMeters: 10,
        elapsed: Duration(minutes: 6),
      ));
      expect(st.state, JourneyState.approaching);
      expect(st.stopsRemaining, 1);

      // Durak 4'te: varış.
      st = engine.update(const GpsSample(
        point: LatLng(41.0, 29.048),
        accuracyMeters: 10,
        elapsed: Duration(minutes: 8),
      ));
      expect(st.state, JourneyState.arrived);
      expect(st.stopsRemaining, 0);
    });

    test('kalan mesafe ve ETA hattı takip eder', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
      );
      final st = engine.update(const GpsSample(
        point: LatLng(41.0, 29.000),
        accuracyMeters: 5,
        elapsed: Duration.zero,
      ));
      // 4 segment x ~1 km ≈ 4 km
      expect(st.distanceToTargetMeters, closeTo(4000, 500));
      // 4 segment x 120 sn = 480 sn
      expect(st.etaSeconds, closeTo(480, 10));
    });
  });

  group('JourneyEngine ters yön', () {
    test('s4->s0 yolculuğunda duraklar ters sırada azalır', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's4',
        targetStopId: 's0',
        alarmStopsThreshold: 1,
      );
      // s4 yakınında başla
      var st = engine.update(const GpsSample(
        point: LatLng(41.0, 29.048),
        accuracyMeters: 10,
        elapsed: Duration.zero,
      ));
      expect(st.state, JourneyState.active);
      expect(st.stopsRemaining, 4);
      expect(st.nextStopName, 'Durak 3');

      // s0'a varış
      st = engine.update(const GpsSample(
        point: LatLng(41.0, 29.000),
        accuracyMeters: 10,
        elapsed: Duration(minutes: 8),
      ));
      expect(st.state, JourneyState.arrived);
    });
  });

  group('Simülasyon akışı (canlı takip)', () {
    test('hat boyunca ilerledikçe durum active->approaching->arrived akar', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
        alarmDistanceMeters: 500,
      );
      final pts = [for (final s in line.stops) LatLng(s.lat, s.lon)];
      final seen = <JourneyState>{};
      JourneyState? last;
      // 0..4 segment ilerlemesini küçük adımlarla simüle et.
      for (var p = 0.0; p <= 4.0; p += 0.1) {
        final seg = p.floor().clamp(0, 3);
        final frac = p - seg;
        final pos = LatLng(
          pts[seg].lat + (pts[seg + 1].lat - pts[seg].lat) * frac,
          pts[seg].lon + (pts[seg + 1].lon - pts[seg].lon) * frac,
        );
        last = engine
            .update(GpsSample(
                point: pos,
                accuracyMeters: 8,
                elapsed: Duration(seconds: (p * 120).round())))
            .state;
        seen.add(last);
      }
      expect(seen.contains(JourneyState.active), isTrue);
      expect(seen.contains(JourneyState.approaching), isTrue);
      expect(last, JourneyState.arrived);
    });
  });

  group('Emniyet kemeri', () {
    test('planlanan süre dolmadan alarmı zorlamaz, dolunca zorlar', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
      );
      // Binişte (hat üzerinde) aktive et; kemer sayacı bu andan işler.
      engine.update(const GpsSample(
        point: LatLng(41.0, 29.000),
        accuracyMeters: 10,
        elapsed: Duration.zero,
      ));
      // Toplam 480 sn planlı.
      expect(engine.totalPlannedSeconds, 480);
      expect(engine.shouldForceAlarm(100), isFalse);
      // 480 - 60 margin = 420. sn 420'de zorlamalı.
      expect(engine.shouldForceAlarm(420), isTrue);
    });

    test('biniş algılanmadan kemer hiç işlemez', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
      );
      // Hiç GPS örneği yok veya hatta binilmedi: süre ne olursa olsun
      // zorlamaz (alarm kurulum anından değil binişten planlanır).
      expect(engine.shouldForceAlarm(100000), isFalse);
    });

    test('varış sonrası zorlamaz', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
      );
      engine.update(const GpsSample(
        point: LatLng(41.0, 29.048),
        accuracyMeters: 5,
        elapsed: Duration(minutes: 8),
      ));
      expect(engine.state, JourneyState.arrived);
      expect(engine.shouldForceAlarm(100000), isFalse);
    });
  });

  group('Biniş öncesi (BEKLEMEDE) — Dilovası senaryosu', () {
    test('hattan uzakta waiting kalır; ne yaklaşma ne kemer tetiklenir', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
      );

      // Alarm, biniş durağının ~7 km uzağında (evde) kuruldu.
      var st = engine.update(const GpsSample(
        point: LatLng(41.0, 28.916),
        accuracyMeters: 15,
        elapsed: Duration.zero,
      ));
      expect(st.state, JourneyState.waiting);
      expect(st.nextStopName, 'Durak 0'); // biniş durağı

      // Araçla binişe gidilirken (15 dk geçti): hâlâ waiting, kemer YOK.
      st = engine.update(const GpsSample(
        point: LatLng(41.0, 28.940),
        accuracyMeters: 15,
        elapsed: Duration(minutes: 15),
      ));
      expect(st.state, JourneyState.waiting);
      expect(engine.shouldForceAlarm(30 * 60), isFalse);

      // Biniş durağına varıldı (30. dk): AKTİF olur, kemer bu andan sayar.
      st = engine.update(const GpsSample(
        point: LatLng(41.0, 29.000),
        accuracyMeters: 15,
        elapsed: Duration(minutes: 30),
      ));
      expect(st.state, JourneyState.active);
      expect(st.stopsRemaining, 4);
      // Planlanan 480 sn biniş ANINA eklenir; kurulumdan itibaren değil.
      expect(engine.shouldForceAlarm(30 * 60 + 100), isFalse);
      expect(engine.shouldForceAlarm(30 * 60 + 420), isTrue);
    });

    test('hatta binmiş kullanıcı ilk örnekte doğrudan aktifleşir', () {
      final line = _testLine();
      final engine = JourneyEngine(
        line: line,
        boardingStopId: 's0',
        targetStopId: 's4',
      );
      // Alarm trende/otobüste kuruldu (hat üzerinde, 1. segment ortası).
      final st = engine.update(const GpsSample(
        point: LatLng(41.0, 29.006),
        accuracyMeters: 20,
        elapsed: Duration.zero,
      ));
      expect(st.state, JourneyState.active);
    });
  });
}
