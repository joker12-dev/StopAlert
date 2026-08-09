import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/data/models.dart';
import 'package:stopalert/src/data/timetable.dart';
import 'package:stopalert/src/engine/scheduled_vehicles.dart';

/// Duraklar 0.01° aralıklarla dizili — konum oranı doğrudan okunabilsin.
TransitLine _line({List<int> segments = const [600, 600, 600]}) => TransitLine(
      id: 'bus:R:M2_G',
      code: 'M2',
      name: 'A - D',
      type: LineType.metro,
      stops: [
        for (var i = 0; i <= segments.length; i++)
          Stop(id: 's$i', name: 'D$i', lat: 41.0 + i * 0.01, lon: 29.0),
      ],
      segmentSeconds: segments,
    );

Departure _dep(String time) =>
    Departure(time: time, dayType: DayType.weekday, outbound: true);

void main() {
  group('ScheduledVehicles', () {
    test('kalkmamış sefer haritada yer almaz', () {
      final v = ScheduledVehicles.forLine(
        line: _line(),
        departures: [_dep('09:00')],
        now: DateTime(2026, 8, 10, 8, 30),
      );
      expect(v, isEmpty);
    });

    test('varışını çoktan tamamlamış sefer silinir', () {
      // 30 dk'lık hat 09:00'da kalktı; 10:00'da yolda olamaz.
      final v = ScheduledVehicles.forLine(
        line: _line(),
        departures: [_dep('09:00')],
        now: DateTime(2026, 8, 10, 10, 0),
      );
      expect(v, isEmpty);
    });

    test('segmentin tam ortasındaki sefer iki durak arasına konur', () {
      // 09:00 kalkış + 15 dk = 2. segmentin ortası (10-20 dk arası).
      final v = ScheduledVehicles.forLine(
        line: _line(),
        departures: [_dep('09:00')],
        now: DateTime(2026, 8, 10, 9, 15),
      );
      expect(v, hasLength(1));
      // D1 (41.01) ile D2 (41.02) arasının tam ortası.
      expect(v.first.lat, closeTo(41.015, 0.0001));
      expect(v.first.nearestStopCode, 's2', reason: 'yaklaştığı durak');
      expect(v.first.scheduled, isTrue);
      expect(v.first.plate, contains('09:00'));
    });

    test('gece yarısını aşan sefer kaybolmaz', () {
      // 23:50'de kalkan sefer 30 dk sürüyor; 00:05'te hâlâ yolda.
      final v = ScheduledVehicles.forLine(
        line: _line(),
        departures: [_dep('23:50')],
        now: DateTime(2026, 8, 11, 0, 5),
      );
      expect(v, hasLength(1),
          reason: 'önceki günden devam eden sefer de sayılmalı');
      expect(v.first.lat, closeTo(41.015, 0.0001));
    });

    test('aynı anda yolda olan birden çok sefer ayrı ayrı çizilir', () {
      final v = ScheduledVehicles.forLine(
        line: _line(),
        departures: [_dep('09:00'), _dep('09:10'), _dep('09:20')],
        now: DateTime(2026, 8, 10, 9, 25),
      );
      // 09:00 seferi 25 dk'da hâlâ yolda (30 dk sürüyor), 09:10 ve 09:20 de.
      expect(v, hasLength(3));
      // İlk kalkan en ileride olmalı.
      expect(v[0].lat, greaterThan(v[1].lat));
      expect(v[1].lat, greaterThan(v[2].lat));
    });

    test('yön kodu varyanttan taşınır — karşı yön süzgeci çalışsın', () {
      final v = ScheduledVehicles.forLine(
        line: _line(),
        departures: [_dep('09:00')],
        now: DateTime(2026, 8, 10, 9, 5),
      );
      expect(v.first.isGidis, isTrue);
      expect(v.first.routeCode, contains('_G_'));
    });

    test('süresi bilinmeyen hat konum üretmez', () {
      final v = ScheduledVehicles.forLine(
        line: _line(segments: const [0, 0, 0]),
        departures: [_dep('09:00')],
        now: DateTime(2026, 8, 10, 9, 5),
      );
      expect(v, isEmpty, reason: 'sıfır süreyle konum uydurulamaz');
    });
  });
}
