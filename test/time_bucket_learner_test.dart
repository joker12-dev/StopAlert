import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/data/timetable.dart';
import 'package:stopalert/src/engine/segment_learner.dart';
import 'package:stopalert/src/engine/time_bucket.dart';

/// Segment sürelerinin ZAMANA KOŞULLU öğrenilmesi.
///
/// Bu, tahmin doğruluğundaki en büyük tek kaldıraç: aynı iki durak arası
/// akşam zirvesinde gecenin iki katı sürüyor. Tek ortalama ikisini de yanlış
/// tahmin ediyordu.
void main() {
  const line = 'bus:147_G';
  const a = 's1';
  const b = 's2';

  final aksamZirvesi =
      const TimeBucket(DayType.weekday, TimeBand.aksamZirve);
  final gece = const TimeBucket(DayType.weekday, TimeBand.gece);

  group('Zaman kovası', () {
    test('saat doğru banda düşer', () {
      expect(TimeBand.forHour(3), TimeBand.gece);
      expect(TimeBand.forHour(8), TimeBand.sabahZirve);
      expect(TimeBand.forHour(13), TimeBand.gunduz);
      expect(TimeBand.forHour(18), TimeBand.aksamZirve);
      expect(TimeBand.forHour(22), TimeBand.aksam);
      // Sınırlar: bant başlangıcı o banda aittir.
      expect(TimeBand.forHour(6), TimeBand.sabahZirve);
      expect(TimeBand.forHour(16), TimeBand.aksamZirve);
    });

    test('kova kodu gün tipi + bant', () {
      // 2026-08-10 pazartesi 18:00 → iş günü, akşam zirvesi.
      final k = TimeBucket.of(DateTime(2026, 8, 10, 18, 30));
      expect(k.code, 'Ie');
      expect(TimeBucket.fromCode('Ie'), k);
      expect(TimeBucket.fromCode('XX'), isNull);
      expect(TimeBucket.fromCode('I'), isNull);
    });

    test('hafta sonu ayrı kova üretir', () {
      final ctesi = TimeBucket.of(DateTime(2026, 8, 8, 18));   // cumartesi
      final pazartesi = TimeBucket.of(DateTime(2026, 8, 10, 18));
      expect(ctesi.code, isNot(pazartesi.code));
    });
  });

  group('Koşullu öğrenme', () {
    test('aynı segment farklı kovalarda farklı süre öğrenir', () {
      final l = SegmentLearner();
      // Akşam zirvesi: yavaş. Gece: hızlı.
      for (var i = 0; i < 5; i++) {
        l.observe(line, a, b, 240, bucketCode: aksamZirvesi.code);
        l.observe(line, a, b, 90, bucketCode: gece.code);
      }
      final aksam = l.learnedSeconds(line, a, b, bucket: aksamZirvesi)!;
      final geceSn = l.learnedSeconds(line, a, b, bucket: gece)!;

      expect(aksam, greaterThan(200));
      expect(geceSn, lessThan(120));
      // Eskiden tek ortalama vardı ve ikisi de ~165 çıkıyordu.
      expect(aksam - geceSn, greaterThan(100));

      // Kullanıcıya gösterilen sayaç SEGMENT sayar, kova değil.
      expect(l.learnedSegmentCount, 1);
      expect(l.learnedBucketCount, 2);
    });

    test('kova boşsa komşu banda düşer, gün tipini karıştırmaz', () {
      final l = SegmentLearner()
        ..observe(line, a, b, 200, bucketCode: aksamZirvesi.code);

      // Sabah zirvesi ölçülmemiş; komşusu akşam zirvesi (benzer yoğunluk).
      final sabah = const TimeBucket(DayType.weekday, TimeBand.sabahZirve);
      final hit = l.lookup(line, a, b, sabah)!;
      expect(hit.source, LearnedSource.neighbourBand);
      expect(hit.seconds, closeTo(200, 0.01));
    });

    test('hiç kova eşleşmezse tüm kovaların ağırlıklı ortalaması', () {
      final l = SegmentLearner();
      // Yalnızca CUMARTESİ verisi var; pazar sorgusu buraya düşemez
      // (komşu bant aynı gün tipinde aranır) → son çare ortalama.
      final ctesiAksam = const TimeBucket(DayType.saturday, TimeBand.aksam);
      l.observe(line, a, b, 150, bucketCode: ctesiAksam.code);

      final pazar = const TimeBucket(DayType.sunday, TimeBand.gunduz);
      final hit = l.lookup(line, a, b, pazar)!;
      expect(hit.source, LearnedSource.fallback);
      expect(hit.seconds, closeTo(150, 0.01));
    });

    test('öğrenilmemiş segment için null döner (GTFS devreye girsin)', () {
      final l = SegmentLearner();
      expect(l.lookup(line, a, b, gece), isNull);
      expect(l.learnedSeconds(line, a, b, bucket: gece), isNull);
    });
  });

  group('Sürüm yükseltmesi', () {
    test('eski KOVASIZ kayıtlar atılmaz, yedek olarak kullanılır', () {
      // v1 şeması: segment anahtarı → {m, n}
      final old = SegmentLearner.fromJson({
        '$line|$a|$b': {'m': 130.0, 'n': 7},
      });
      expect(old.learnedSegmentCount, 1);

      // Kovalı sorgu: tam eşleşme yok, komşu yok → eski kayda düşer.
      final hit = old.lookup(line, a, b, aksamZirvesi)!;
      expect(hit.source, LearnedSource.fallback);
      expect(hit.seconds, closeTo(130, 0.01));
      expect(hit.samples, 7);
    });

    test('yeni gözlem eski kaydı ezmez, kendi kovasına yazılır', () {
      final l = SegmentLearner.fromJson({
        '$line|$a|$b': {'m': 130.0, 'n': 7},
      });
      l.observe(line, a, b, 260, bucketCode: aksamZirvesi.code);

      // Akşam zirvesi artık kendi değerini verir.
      expect(l.lookup(line, a, b, aksamZirvesi)!.source, LearnedSource.exact);
      expect(l.learnedSeconds(line, a, b, bucket: aksamZirvesi), 260);
      // Eski kayıt hâlâ orada: gün tipi eşleşmeyen sorgu ona düşer.
      final pazar = const TimeBucket(DayType.sunday, TimeBand.gece);
      expect(l.lookup(line, a, b, pazar)!.seconds, closeTo(130, 0.01));
    });

    test('kaydet-yükle çevrimi kovaları korur', () {
      final l = SegmentLearner()
        ..observe(line, a, b, 240, bucketCode: aksamZirvesi.code)
        ..observe(line, a, b, 90, bucketCode: gece.code);

      final round = SegmentLearner.fromJson(l.toJson());
      expect(round.learnedSeconds(line, a, b, bucket: aksamZirvesi), 240);
      expect(round.learnedSeconds(line, a, b, bucket: gece), 90);
    });
  });

  group('Kalabalık tohumlama', () {
    test('kişisel veri o kovada varsa buluttan gelen EZMEZ', () {
      final l = SegmentLearner()
        ..observe(line, a, b, 240, bucketCode: aksamZirvesi.code);
      l.seedIfAbsent(line, a, b, 999, 50, bucketCode: aksamZirvesi.code);
      expect(l.learnedSeconds(line, a, b, bucket: aksamZirvesi), 240);
    });

    test('boş kovaya buluttan tohumlanır', () {
      final l = SegmentLearner()
        ..observe(line, a, b, 240, bucketCode: aksamZirvesi.code);
      l.seedIfAbsent(line, a, b, 95, 40, bucketCode: gece.code);
      expect(l.learnedSeconds(line, a, b, bucket: gece), 95);
      // Kişisel kova bozulmadı.
      expect(l.learnedSeconds(line, a, b, bucket: aksamZirvesi), 240);
    });
  });
}
