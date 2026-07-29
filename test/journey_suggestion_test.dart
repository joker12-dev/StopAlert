import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/data/journey_record.dart';
import 'package:stopalert/src/data/journey_suggestion.dart';

JourneyRecord _rec(DateTime at,
        {String route = 'A', String status = 'completed'}) =>
    JourneyRecord(
      lineCode: 'M2',
      lineName: 'M2 Hattı',
      lineTypeName: 'metro',
      boardingStopName: route == 'A' ? 'Taksim' : 'Kadıköy',
      targetStopName: route == 'A' ? 'Levent' : 'Kartal',
      durationSeconds: 1200,
      stopsTraveled: 5,
      status: status,
      createdAt: at,
    );

void main() {
  group('JourneySuggester', () {
    // 2026-07-27 bir Pazartesi.
    final monday18 = DateTime(2026, 7, 27, 18, 0);

    test('boş geçmiş öneri vermez', () {
      expect(JourneySuggester.suggest(const [], monday18), isNull);
    });

    test('aynı gün+saatte 3 tekrar öneri üretir', () {
      final history = [
        _rec(DateTime(2026, 7, 6, 18, 5)), // önceki pazartesiler ~18:00
        _rec(DateTime(2026, 7, 13, 17, 50)),
        _rec(DateTime(2026, 7, 20, 18, 10)),
      ];
      final s = JourneySuggester.suggest(history, monday18);
      expect(s, isNotNull);
      expect(s!.boardingStopName, 'Taksim');
      expect(s.targetStopName, 'Levent');
      expect(s.occurrences, 3);
    });

    test('yetersiz tekrar (2) öneri vermez', () {
      final history = [
        _rec(DateTime(2026, 7, 13, 18, 0)),
        _rec(DateTime(2026, 7, 20, 18, 0)),
      ];
      expect(JourneySuggester.suggest(history, monday18), isNull);
    });

    test('farklı gün/saatteki yolculuklar sayılmaz', () {
      final history = [
        _rec(DateTime(2026, 7, 7, 18, 0)), // Salı
        _rec(DateTime(2026, 7, 14, 9, 0)), // Pazartesi ama sabah
        _rec(DateTime(2026, 7, 20, 18, 0)), // Pazartesi 18:00
      ];
      // Yalnızca 1 eşleşme (20 Temmuz) -> öneri yok.
      expect(JourneySuggester.suggest(history, monday18), isNull);
    });

    test('bugün zaten yapıldıysa önermez', () {
      final history = [
        _rec(DateTime(2026, 7, 6, 18, 0)),
        _rec(DateTime(2026, 7, 13, 18, 0)),
        _rec(DateTime(2026, 7, 20, 18, 0)),
        _rec(DateTime(2026, 7, 27, 8, 0)), // bugün (sabah) yapılmış
      ];
      expect(JourneySuggester.suggest(history, monday18), isNull);
    });

    test('iptal edilen yolculuklar sayılmaz', () {
      final history = [
        _rec(DateTime(2026, 7, 6, 18, 0), status: 'cancelled'),
        _rec(DateTime(2026, 7, 13, 18, 0), status: 'cancelled'),
        _rec(DateTime(2026, 7, 20, 18, 0), status: 'cancelled'),
      ];
      expect(JourneySuggester.suggest(history, monday18), isNull);
    });
  });
}
