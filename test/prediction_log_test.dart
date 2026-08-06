import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/services/prediction_log.dart';

/// Tahmin ↔ gerçek defteri.
///
/// Bu, "tahminler iyileşiyor" demenin tek dürüst yolu: değişikliğin etkisi
/// ölçülmeden bilinemez. Hatanın İŞARETİ ayrıca tutulur — ortalama mutlak
/// hata "ne kadar şaşırdığımızı", işaretli ortalama "hangi yöne şaştığımızı"
/// söyler ve sapma düzeltmesi ikincisine dayanır.
void main() {
  PredictionRecord rec(int predicted, int actual,
          {String bucket = 'Id', String line = '147'}) =>
      PredictionRecord(
        lineCode: line,
        bucketCode: bucket,
        predictedSeconds: predicted,
        actualSeconds: actual,
        at: DateTime(2026, 8, 10, 13),
      );

  group('Hata hesabı', () {
    test('pozitif hata = tahmin KISA kaldı', () {
      expect(rec(600, 720).errorSeconds, 120);
      expect(rec(600, 480).errorSeconds, -120);
    });
  });

  group('Özet', () {
    test('mutlak hata ile işaretli sapma ayrı ayrı hesaplanır', () {
      // +120 ve -120: mutlak ortalama 120, sapma 0 (sistematik kayma yok).
      final a = PredictionLog.summarize([rec(600, 720), rec(600, 480)]);
      expect(a.samples, 2);
      expect(a.meanAbsErrorSeconds, closeTo(120, 0.01));
      expect(a.meanBiasSeconds, closeTo(0, 0.01));

      // İkisi de kısa kaldı: sapma pozitif — düzeltme buradan gelecek.
      final b = PredictionLog.summarize([rec(600, 720), rec(600, 780)]);
      expect(b.meanBiasSeconds, closeTo(150, 0.01));
    });

    test('zaman kovasına göre süzülür', () {
      final rows = [
        rec(600, 900, bucket: 'Ie'),   // akşam zirvesi: çok kısa kalmış
        rec(600, 610, bucket: 'In'),   // gece: neredeyse tam
        rec(600, 940, bucket: 'Ie'),
      ];
      final aksam = PredictionLog.summarize(rows, bucketCode: 'Ie');
      final gece = PredictionLog.summarize(rows, bucketCode: 'In');

      expect(aksam.samples, 2);
      expect(gece.samples, 1);
      // Sapma saat dilimine göre DEĞİŞİYOR — tek bir düzeltme katsayısı
      // yeterli olmazdı, bu yüzden kova bazında bakılıyor.
      expect(aksam.meanBiasSeconds, greaterThan(300));
      expect(gece.meanBiasSeconds, lessThan(30));
    });

    test('hatta göre süzülür', () {
      final rows = [
        rec(600, 900, line: '147'),
        rec(600, 610, line: '34'),
      ];
      expect(PredictionLog.summarize(rows, lineCode: '34').samples, 1);
    });

    test('kayıt yoksa boş özet', () {
      expect(PredictionLog.summarize(const []).samples, 0);
      expect(PredictionLog.summarize(const []).meanAbsErrorSeconds, 0);
    });
  });
}
