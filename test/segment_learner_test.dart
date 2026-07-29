import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/engine/segment_learner.dart';

void main() {
  group('SegmentLearner', () {
    test('ilk gözlem doğrudan öğrenilir', () {
      final l = SegmentLearner();
      expect(l.learnedSeconds('M2', 'a', 'b'), isNull);
      l.observe('M2', 'a', 'b', 120);
      expect(l.learnedSeconds('M2', 'a', 'b'), 120);
      expect(l.learnedSegmentCount, 1);
    });

    test('EMA tekrar eden gözleme doğru yakınsar', () {
      final l = SegmentLearner();
      l.observe('M2', 'a', 'b', 100);
      for (var i = 0; i < 20; i++) {
        l.observe('M2', 'a', 'b', 140);
      }
      final learned = l.learnedSeconds('M2', 'a', 'b')!;
      expect(learned, closeTo(140, 3));
    });

    test('yön (from->to) ayrı öğrenilir', () {
      final l = SegmentLearner();
      l.observe('M2', 'a', 'b', 100);
      l.observe('M2', 'b', 'a', 200);
      expect(l.learnedSeconds('M2', 'a', 'b'), 100);
      expect(l.learnedSeconds('M2', 'b', 'a'), 200);
    });

    test('aykırı gözlem yeterli örnekten sonra kırpılır', () {
      final l = SegmentLearner();
      // Kararlı 100 sn taban oluştur.
      for (var i = 0; i < 6; i++) {
        l.observe('M2', 'a', 'b', 100);
      }
      final before = l.learnedSeconds('M2', 'a', 'b')!;
      // 10x'lik bir sıçrama (ör. uzun sinyal beklemesi) modeli ele geçirmesin.
      l.observe('M2', 'a', 'b', 1000);
      final after = l.learnedSeconds('M2', 'a', 'b')!;
      // 3x tavana (300) kırpıldığı için ortalama makul kalır (<= 200).
      expect(after, lessThan(200));
      expect(after, greaterThan(before));
    });

    test('fiziksel olmayan gözlemler yok sayılır', () {
      final l = SegmentLearner();
      l.observe('M2', 'a', 'b', 0); // çok küçük
      l.observe('M2', 'a', 'b', 5000); // 30 dk üstü
      expect(l.learnedSeconds('M2', 'a', 'b'), isNull);
      expect(l.learnedSegmentCount, 0);
    });

    test('seedIfAbsent yalnızca kişisel veri yoksa tohumlar', () {
      final l = SegmentLearner();
      // Kişisel veri yokken bulut tohumu eklenir.
      l.seedIfAbsent('M2', 'a', 'b', 150, 40);
      expect(l.learnedSeconds('M2', 'a', 'b'), 150);

      // Kişisel gözlem gelince kişisel öncelikli; tohum EZMEZ.
      final l2 = SegmentLearner()..observe('M2', 'a', 'b', 100);
      l2.seedIfAbsent('M2', 'a', 'b', 300, 40);
      expect(l2.learnedSeconds('M2', 'a', 'b'), 100);
    });

    test('seedIfAbsent fiziksel olmayan değeri yok sayar', () {
      final l = SegmentLearner();
      l.seedIfAbsent('M2', 'a', 'b', 5000, 40); // 30 dk üstü
      expect(l.learnedSeconds('M2', 'a', 'b'), isNull);
    });

    test('JSON gidiş-dönüş modeli korur', () {
      final l = SegmentLearner();
      l.observe('M2', 'a', 'b', 100);
      l.observe('T1', 'x', 'y', 200);
      final restored = SegmentLearner.fromJson(l.toJson());
      expect(restored.learnedSeconds('M2', 'a', 'b'), 100);
      expect(restored.learnedSeconds('T1', 'x', 'y'), 200);
      expect(restored.learnedSegmentCount, 2);
    });
  });
}
