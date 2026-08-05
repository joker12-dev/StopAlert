import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:stopalert/src/util/latlng_guard.dart';

/// Harita noktalarının sonluluk denetimi.
///
/// Bu denetim kozmetik değil: sonsuz/NaN koordinatlı tek bir marker,
/// flutter_map'in izdüşüm adımını HER KAREDE hataya düşürüyor. Hata layout
/// içinde atıldığı için çerçeve yeniden denemeye devam ediyor; uygulama
/// %196 CPU'ya çıkıp saniyede on binlerce nesne ayırıyor, bellek baskısı
/// sistemi başka uygulamaları öldürmeye zorluyor ve ana iş parçacığı
/// kilitlenince ANR ile çöküyor. Cihaz logunda birebir görüldü:
/// "RangeError: All markers must have finite `point`s".
void main() {
  group('Nokta kullanılabilirliği', () {
    test('gerçek koordinatlar kabul edilir', () {
      expect(const LatLng(41.0082, 28.9784).isUsable, isTrue);   // İstanbul
      expect(const LatLng(40.7654, 29.9408).isUsable, isTrue);   // İzmit
      expect(const LatLng(0, 0).isUsable, isTrue);
      expect(const LatLng(-90, 180).isUsable, isTrue);           // uç değerler
    });

    test('NaN ve sonsuz reddedilir', () {
      expect(LatLng(double.nan, 28.9).isUsable, isFalse);
      expect(LatLng(41.0, double.nan).isUsable, isFalse);
      expect(LatLng(double.infinity, 28.9).isUsable, isFalse);
      expect(LatLng(41.0, double.negativeInfinity).isUsable, isFalse);
      expect(LatLng(double.nan, double.nan).isUsable, isFalse);
    });

    test('dünya sınırları dışı reddedilir', () {
      // Bozuk ondalık ayrıştırma böyle değerler üretebiliyor.
      expect(const LatLng(407.62, 29.95).isUsable, isFalse);
      expect(const LatLng(41.0, 2995.7).isUsable, isFalse);
    });
  });

  group('safeLatLng', () {
    test('geçerli değerde nokta döner', () {
      final p = safeLatLng(41.0082, 28.9784);
      expect(p, isNotNull);
      expect(p!.latitude, closeTo(41.0082, 1e-9));
    });

    test('geçersiz değerde null döner — çağıran atlayabilsin', () {
      expect(safeLatLng(double.nan, 28.9), isNull);
      expect(safeLatLng(41.0, double.infinity), isNull);
      expect(safeLatLng(999, 999), isNull);
    });

    test('0/0 ayıklanmaz — geçerli bir koordinattır', () {
      // Uygulamada "koordinatsız durak" ayrı bir kuralla (lat==0 && lon==0)
      // eleniyor; bu yardımcının işi yalnızca SONLULUK.
      expect(safeLatLng(0, 0), isNotNull);
    });
  });

  group('onlyUsable', () {
    test('bozuk noktaları ayıklar, sırayı korur', () {
      final out = onlyUsable([
        const LatLng(41.0, 29.0),
        LatLng(double.nan, 29.1),
        const LatLng(41.2, 29.2),
        LatLng(41.3, double.infinity),
      ]);
      expect(out.length, 2);
      expect(out.first.latitude, closeTo(41.0, 1e-9));
      expect(out.last.latitude, closeTo(41.2, 1e-9));
    });

    test('tamamı bozuksa boş liste', () {
      final out = onlyUsable([
        LatLng(double.nan, double.nan),
        LatLng(double.infinity, 0),
      ]);
      expect(out, isEmpty);
    });
  });
}
