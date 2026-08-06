import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/data/models.dart';
import 'package:stopalert/src/data/timetable.dart';
import 'package:stopalert/src/engine/arrival_estimator.dart';
import 'package:stopalert/src/engine/segment_learner.dart';
import 'package:stopalert/src/engine/time_bucket.dart';
import 'package:stopalert/src/services/iett_service.dart';

/// Durağa varış tahmini — canlı araç konumundan.
///
/// İETT hazır varış süresi yayınlamıyor; sayı burada üretiliyor. Bu testler
/// hesabın kurallarını sabitliyor: durağı geçen araç gösterilmez, bayat konum
/// düzeltilir, öğrenilmiş süre tarifeyi ezer.
void main() {
  /// 5 duraklı düz hat, ~1 km aralıklı (boylamda 0,012° ≈ 1 km).
  TransitLine line() => const TransitLine(
        id: 'bus:T_G',
        code: 'T',
        name: 'Test',
        type: LineType.bus,
        segmentSeconds: [120, 120, 120, 120],
        stops: [
          Stop(id: 'bus:100', name: 'D0', lat: 41.0, lon: 29.000),
          Stop(id: 'bus:101', name: 'D1', lat: 41.0, lon: 29.012),
          Stop(id: 'bus:102', name: 'D2', lat: 41.0, lon: 29.024),
          Stop(id: 'bus:103', name: 'D3', lat: 41.0, lon: 29.036),
          Stop(id: 'bus:104', name: 'D4', lat: 41.0, lon: 29.048),
        ],
      );

  BusVehicle bus(String plate, String nearStop, {String seen = ''}) =>
      BusVehicle(
        plate: plate,
        lat: 41.0,
        lon: 29.0,
        headingTo: 'D4',
        routeCode: 'T_G_D0',
        lastSeen: seen,
        nearestStopCode: nearStop,
      );

  final now = DateTime(2026, 8, 10, 13, 0); // pazartesi, gündüz

  group('Temel hesap', () {
    test('araç durak sayısı kadar segment süresi toplar', () {
      final r = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:103',
        vehicles: [bus('A', '101')],
        now: now,
      );
      expect(r.length, 1);
      expect(r.single.stopsAway, 2);
      // 2 segment x 120 sn (mesafeler eşit olduğu için dağıtım da eşit).
      expect(r.single.seconds, closeTo(240, 10));
    });

    test('durağı GEÇMİŞ araç listelenmez', () {
      final r = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:101',
        // 102 ve 103, hedef olan 101'in ilerisinde.
        vehicles: [bus('A', '102'), bus('B', '103')],
        now: now,
      );
      expect(r, isEmpty);
    });

    test('sonuçlar en yakın varıştan uzağa sıralı', () {
      final r = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:104',
        vehicles: [bus('uzak', '100'), bus('yakin', '103')],
        now: now,
      );
      expect(r.map((e) => e.vehicle.plate), ['yakin', 'uzak']);
    });

    test('tanınmayan durak kodu + hattan uzak konum elenir', () {
      final r = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:104',
        vehicles: [
          BusVehicle(
            plate: 'X',
            lat: 40.0, // hattan ~110 km uzakta
            lon: 28.0,
            headingTo: '',
            routeCode: '',
            lastSeen: '',
            nearestStopCode: '999999',
          ),
        ],
        now: now,
      );
      expect(r, isEmpty);
    });
  });

  group('Bayat konum düzeltmesi', () {
    test('tek araçlık fotoğrafta düzeltme yapılmaz (referans kendisi)', () {
      // Tek araç varsa "en yeni damga" onun kendisidir; yaş sıfırdır.
      // Bu bilinçli: cihaz saatine güvenip yanlış düzeltme yapmaktansa
      // hiç düzeltmemek yeğdir.
      final r = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:103',
        vehicles: [bus('A', '101', seen: '2026-08-10 12:58:30')],
        now: now,
      ).single;
      expect(r.seconds, closeTo(240, 10));
    });

    test('çözülemeyen zaman damgası düzeltme YAPMAZ', () {
      final r = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:103',
        vehicles: [bus('A', '101', seen: 'bilinmiyor')],
        now: now,
      ).single;
      expect(r.seconds, closeTo(240, 10));
    });

    test('cihaz saati kaymışsa bile liste boşalmaz', () {
      // Damgalar İstanbul yerel saatinde; cihaz saati 5 saat geride olsun.
      // Tazelik cihaz saatinden değil, aynı fotoğraftaki EN YENİ damgadan
      // ölçüldüğü için araçlar elenmemeli ve düzeltme sıfır olmalı.
      final r = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:103',
        vehicles: [bus('A', '101', seen: '2026-08-10 18:00:00')],
        now: now,
      );
      expect(r.length, 1);
      expect(r.single.seconds, closeTo(240, 10));
    });

    test('göreli yaş: aynı fotoğrafta geri kalan araç düzeltilir', () {
      // İki araç aynı yayında: biri 90 sn daha eski. Referans en yeni damga.
      final r = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:103',
        vehicles: [
          bus('yeni', '101', seen: '2026-08-10 13:00:00'),
          bus('eski', '101', seen: '2026-08-10 12:58:30'),
        ],
        now: now,
      );
      expect(r.length, 2);
      final yeni = r.firstWhere((e) => e.vehicle.plate == 'yeni');
      final eski = r.firstWhere((e) => e.vehicle.plate == 'eski');
      expect(yeni.seconds - eski.seconds, closeTo(90, 2));
    });
  });

  group('Aktif olmayan araçlar', () {
    test('fotoğraftaki taze araçlardan çok geride kalan LİSTELENMEZ', () {
      // Servis, seferi bitmiş aracı listede bırakabiliyor; onu "yaklaşıyor"
      // diye göstermek gelmeyecek bir otobüsü beklettirmek olur.
      final r = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:103',
        vehicles: [
          bus('taze', '101', seen: '2026-08-10 13:00:00'),
          bus('eski', '101', seen: '2026-08-10 12:50:00'), // 10 dk geride
        ],
        now: now,
      );
      expect(r.map((e) => e.vehicle.plate), ['taze']);
    });

    test('sınırın içindeki araç listelenir', () {
      final r = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:103',
        vehicles: [
          bus('taze', '101', seen: '2026-08-10 13:00:00'),
          bus('biraz', '101', seen: '2026-08-10 12:58:00'), // 2 dk geride
        ],
        now: now,
      );
      expect(r.length, 2);
    });

    test('zaman damgası okunamıyorsa araç ELENMEZ', () {
      // Okuyamadığımız bir alan yüzünden gerçekten yolda olan otobüsü
      // gizlemektense göstermek yeğdir.
      final r = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:103',
        vehicles: [bus('A', '101', seen: 'bilinmiyor'), bus('B', '101')],
        now: now,
      );
      expect(r.length, 2);
    });
  });

  group('Öğrenilmiş süre', () {
    test('o saat dilimine ait ölçüm tarifeyi EZER', () {
      final l = SegmentLearner();
      final gunduz = const TimeBucket(DayType.weekday, TimeBand.gunduz);
      // Gerçekte bu iki segment tarifedekinin iki katı sürüyor.
      l.observe('bus:T_G', 'bus:101', 'bus:102', 240,
          bucketCode: gunduz.code);
      l.observe('bus:T_G', 'bus:102', 'bus:103', 240,
          bucketCode: gunduz.code);

      final r = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:103',
        vehicles: [bus('A', '101')],
        learner: l,
        now: now,
      ).single;

      expect(r.seconds, closeTo(480, 10));
      expect(r.quality, ArrivalQuality.learned);
    });

    test('ölçüm yoksa kalite "tarife" ve belirsizlik daha geniş', () {
      final tarife = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:103',
        vehicles: [bus('A', '101')],
        now: now,
      ).single;
      expect(tarife.quality, ArrivalQuality.schedule);

      final l = SegmentLearner();
      final gunduz = const TimeBucket(DayType.weekday, TimeBand.gunduz);
      l.observe('bus:T_G', 'bus:101', 'bus:102', 120, bucketCode: gunduz.code);
      l.observe('bus:T_G', 'bus:102', 'bus:103', 120, bucketCode: gunduz.code);
      final olculmus = ArrivalEstimator.forStop(
        line: line(),
        targetStopId: 'bus:103',
        vehicles: [bus('A', '101')],
        learner: l,
        now: now,
      ).single;

      // Aynı süre, ama ölçülmüş olanın aralığı dar.
      expect(olculmus.spreadSeconds, lessThan(tarife.spreadSeconds));
    });
  });

  group('Kullanıcıya gösterilen aralık', () {
    test('tek sayı değil aralık üretir', () {
      const e = ArrivalEstimate(
        vehicle: BusVehicle(
            plate: 'A',
            lat: 0,
            lon: 0,
            headingTo: '',
            routeCode: '',
            lastSeen: '',
            nearestStopCode: ''),
        stopsAway: 3,
        seconds: 300,
        spreadSeconds: 90,
        quality: ArrivalQuality.partial,
      );
      // 210..390 sn → 3-7 dk
      expect(e.rangeLabel, '3-7 dk');
    });

    test('çok yakınsa "şimdi"', () {
      const e = ArrivalEstimate(
        vehicle: BusVehicle(
            plate: 'A',
            lat: 0,
            lon: 0,
            headingTo: '',
            routeCode: '',
            lastSeen: '',
            nearestStopCode: ''),
        stopsAway: 1,
        seconds: 10,
        spreadSeconds: 40,
        quality: ArrivalQuality.learned,
      );
      expect(e.rangeLabel, 'şimdi');
    });
  });

  group('Segment süresi mesafeye göre dağıtılır', () {
    test('uzun segment daha çok süre alır, toplam korunur', () {
      // İlk segment ~1 km, ikinci ~3 km.
      const uneven = TransitLine(
        id: 'bus:U_G',
        code: 'U',
        name: 'Dengesiz',
        type: LineType.bus,
        // Ham veri EŞİT dağıtıyor (resmi sefer süresi ÷ segment sayısı).
        segmentSeconds: [120, 120],
        stops: [
          Stop(id: 'bus:1', name: 'A', lat: 41.0, lon: 29.000),
          Stop(id: 'bus:2', name: 'B', lat: 41.0, lon: 29.012),
          Stop(id: 'bus:3', name: 'C', lat: 41.0, lon: 29.048),
        ],
      );
      final s = ArrivalEstimator.segmentSecondsFor(uneven);
      expect(s.length, 2);
      expect(s[1], greaterThan(s[0] * 2), reason: '3 kat uzun segment');
      expect(s[0] + s[1], closeTo(240, 6), reason: 'toplam korunur');
    });

    test('koordinat yoksa ham değerler korunur', () {
      const noCoords = TransitLine(
        id: 'bus:N_G',
        code: 'N',
        name: 'Koordinatsız',
        type: LineType.bus,
        segmentSeconds: [100, 200],
        stops: [
          Stop(id: 'bus:1', name: 'A', lat: 0, lon: 0),
          Stop(id: 'bus:2', name: 'B', lat: 0, lon: 0),
          Stop(id: 'bus:3', name: 'C', lat: 0, lon: 0),
        ],
      );
      expect(ArrivalEstimator.segmentSecondsFor(noCoords), [100, 200]);
    });
  });
}
