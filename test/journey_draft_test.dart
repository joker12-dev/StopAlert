import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/data/models.dart';
import 'package:stopalert/src/data/sample_lines.dart';

void main() {
  group('TransitLine', () {
    test('stopsBetween yön bağımsız doğru sayar', () {
      final gebze = marmaray.stops.first.id;
      final halkali = marmaray.stops.last.id;
      expect(marmaray.stopsBetween(gebze, halkali), marmaray.stops.length - 1);
      expect(marmaray.stopsBetween(halkali, gebze), marmaray.stops.length - 1);
    });

    test('estimatedTravelTime segment süresini kullanır', () {
      final s0 = m2.stops[0].id;
      final s4 = m2.stops[4].id;
      expect(
        m2.estimatedTravelTime(s0, s4),
        Duration(seconds: 4 * m2.defaultSegmentSeconds),
      );
    });
  });

  group('JourneyDraft', () {
    test('hat değişince durak seçimleri sıfırlanır', () {
      var draft = JourneyDraft(
        line: marmaray,
        boardingStopId: marmaray.stops[5].id,
        targetStopId: marmaray.stops[10].id,
      );
      expect(draft.isComplete, isTrue);

      draft = draft.copyWith(line: m2);
      expect(draft.line!.id, 'M2');
      expect(draft.boardingStopId, isNull);
      expect(draft.targetStopId, isNull);
      expect(draft.isComplete, isFalse);
    });
  });
}
