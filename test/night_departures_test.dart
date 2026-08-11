import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/data/models.dart';
import 'package:stopalert/src/data/timetable.dart';
import 'package:stopalert/src/engine/arrival_estimator.dart';
import 'package:stopalert/src/engine/scheduled_vehicles.dart';

/// Gece yarısını aşan kalkışlar 24'ü aşan saatlerle yazılıyor ("25:28").
/// Bu, seferin KALKTIĞI güne ait kalmasını sağlıyor; sıralama, gösterim ve
/// varış hesabının hepsi bu biçimi doğru okumak zorunda.
Departure _dep(String time, {bool outbound = true}) =>
    Departure(time: time, dayType: DayType.weekday, outbound: outbound);

TransitLine _line() => TransitLine(
      id: 'bus:R:Marmaray_D',
      code: 'Marmaray',
      name: 'Halkalı - Gebze',
      type: LineType.marmaray,
      stops: [
        for (var i = 0; i < 4; i++)
          Stop(id: 's$i', name: 'D$i', lat: 41.0 + i * 0.01, lon: 29.0),
      ],
      segmentSeconds: const [600, 600, 600],
    );

void main() {
  group('Gece seferi saatleri', () {
    test('24+ saat listenin sonuna sıralanır', () {
      final t = Timetable(lineCode: 'Marmaray', departures: [
        _dep('25:28'),
        _dep('05:58'),
        _dep('23:28'),
        _dep('24:28'),
      ]);
      final rows = t.forDay(DayType.weekday, outbound: true);
      expect([for (final d in rows) d.time],
          ['05:58', '23:28', '24:28', '25:28']);
    });

    test('kullanıcıya normal saat yazılır ama ertesi gün işaretlenir', () {
      final d = _dep('25:28');
      expect(d.displayTime, '01:28');
      expect(d.isNextDay, isTrue);
      expect(_dep('23:28').isNextDay, isFalse);
      expect(_dep('23:28').displayTime, '23:28');
    });

    test('gece yarısından sonra sıradaki sefer DÜNKÜ listeden bulunur', () {
      final t = Timetable(lineCode: 'Marmaray', departures: [
        _dep('05:58'),
        _dep('23:58'),
        _dep('24:28'),
        _dep('25:28'),
      ]);
      final rows = t.forDay(DayType.weekday, outbound: true);
      // Saat 00:40 — sıradaki sefer 01:28 (25:28) olmalı, sabahki 05:58 değil.
      final next = t.next(rows, DateTime(2026, 8, 11, 0, 40));
      expect(next?.time, '25:28');
    });

    test('varış hesabı 24+ saati ertesi güne taşır', () {
      // 24:28 = ertesi gün 00:28. 2. durağa 20 dk sonra, yani 00:48'de.
      final arrivals = ScheduledArrivals.fromSchedule(
        line: _line(),
        targetStopId: 's2',
        departures: [_dep('24:28')],
        now: DateTime(2026, 8, 11, 0, 20),
      );
      expect(arrivals, hasLength(1));
      expect(arrivals.first.at.day, 11, reason: 'aynı takvim gününde');
      expect(arrivals.first.clockLabel, '00:48');
    });

    test('gece seferi haritada doğru yerde konumlanır', () {
      // 24:28 kalkışlı sefer, 00:38'de ilk segmentin ortasını geçmiş olmalı.
      final v = ScheduledVehicles.forLine(
        line: _line(),
        departures: [_dep('24:28')],
        now: DateTime(2026, 8, 11, 0, 43),
      );
      expect(v, hasLength(1), reason: 'gece seferi yolda sayılmalı');
      expect(v.first.lat, closeTo(41.015, 0.001));
    });
  });
}
