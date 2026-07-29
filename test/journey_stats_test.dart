import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/data/journey_record.dart';
import 'package:stopalert/src/data/journey_stats.dart';
import 'package:stopalert/src/data/models.dart';

JourneyRecord _rec(String code, String type, int seconds, String status) =>
    JourneyRecord(
      lineCode: code,
      lineName: '$code Hattı',
      lineTypeName: type,
      boardingStopName: 'A',
      targetStopName: 'B',
      durationSeconds: seconds,
      stopsTraveled: 3,
      status: status,
    );

void main() {
  group('JourneyStats', () {
    test('boş geçmiş boş istatistik verir', () {
      final s = JourneyStats.from(const []);
      expect(s.isEmpty, isTrue);
      expect(s.totalJourneys, 0);
      expect(s.completedJourneys, 0);
      expect(s.mostUsedLineCode, isNull);
    });

    test('toplam, tamamlanan ve süre doğru toplanır', () {
      final s = JourneyStats.from([
        _rec('M2', 'metro', 600, 'completed'),
        _rec('M2', 'metro', 1200, 'completed'),
        _rec('Marmaray', 'marmaray', 300, 'cancelled'),
      ]);
      expect(s.totalJourneys, 3);
      expect(s.completedJourneys, 2); // "kaç kez uyandırıldın"
      expect(s.totalSeconds, 2100);
      expect(s.totalMinutes, 35);
    });

    test('en çok kullanılan hattı bulur', () {
      final s = JourneyStats.from([
        _rec('M2', 'metro', 600, 'completed'),
        _rec('M2', 'metro', 600, 'completed'),
        _rec('Marmaray', 'marmaray', 600, 'completed'),
      ]);
      expect(s.mostUsedLineCode, 'M2');
      expect(s.mostUsedLineType, LineType.metro);
      expect(s.mostUsedCount, 2);
    });

    test('süre metni saat/dakika biçimlenir', () {
      expect(JourneyStats.from([_rec('M2', 'metro', 18 * 60, 'completed')])
          .totalDurationText, '18 dk');
      expect(JourneyStats.from([_rec('M2', 'metro', 150 * 60, 'completed')])
          .totalDurationText, '2,5 saat');
      expect(JourneyStats.from([_rec('M2', 'metro', 120 * 60, 'completed')])
          .totalDurationText, '2 saat');
    });
  });
}
