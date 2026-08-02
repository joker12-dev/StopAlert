import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/data/transit_city.dart';

void main() {
  group('Konumdan şehir tahmini', () {
    test('İstanbul içindeki nokta İstanbul verir', () {
      // Taksim
      expect(TransitCities.forLocation(41.0370, 28.9850).id, 'istanbul');
      // Halkalı (batı uç)
      expect(TransitCities.forLocation(41.0184, 28.7665).id, 'istanbul');
      // Kadıköy (Anadolu yakası)
      expect(TransitCities.forLocation(40.9900, 29.0250).id, 'istanbul');
      // Şile: İstanbul'un ilçesi ama Kandıra ile aynı enlem kuşağında —
      // Kocaeli kutusu kuzeyden kesilmezse yanlış şehre düşüyordu.
      expect(TransitCities.forLocation(41.1750, 29.6130).id, 'istanbul');
      // Beykoz kuzeyi
      expect(TransitCities.forLocation(41.1300, 29.1000).id, 'istanbul');
    });

    test('Kocaeli içindeki nokta Kocaeli verir', () {
      // İzmit merkez
      expect(TransitCities.forLocation(40.7654, 29.9408).id, 'kocaeli');
      // Gölcük
      expect(TransitCities.forLocation(40.7167, 29.8167).id, 'kocaeli');
      // Kandıra (kuzey)
      expect(TransitCities.forLocation(41.0700, 30.1500).id, 'kocaeli');
    });

    test('Gebze Kocaeli sayılır (İstanbul kutusuyla çakışıyor)', () {
      // Gebze idari olarak Kocaeli ama İstanbul'un kutusuna da giriyor;
      // "kutuya giren ilk şehir" kuralı burada yanlış cevap veriyordu.
      expect(TransitCities.forLocation(40.8000, 29.4300).id, 'kocaeli');
      // Dilovası
      expect(TransitCities.forLocation(40.7800, 29.5300).id, 'kocaeli');
    });

    test('hiçbir şehre girmeyen nokta EN YAKIN şehri verir', () {
      // Ankara: iki kutunun da dışında. Boş ekran yerine en yakın seçilmeli.
      final c = TransitCities.forLocation(39.9334, 32.8597);
      expect(TransitCities.all, contains(c));
      // Ankara Kocaeli'ye İstanbul'dan daha yakın.
      expect(c.id, 'kocaeli');
    });

    test('çok uzak nokta bile bir şehir döndürür (asla null değil)', () {
      for (final p in [(0.0, 0.0), (60.0, 10.0), (-33.0, 151.0)]) {
        expect(TransitCities.all, contains(TransitCities.forLocation(p.$1, p.$2)));
      }
    });
  });

  group('Şehir kimliği', () {
    test('bilinmeyen kimlik İstanbul’a düşer', () {
      expect(TransitCities.byId('sakarya').id, 'istanbul');
      expect(TransitCities.byId(null).id, 'istanbul');
      expect(TransitCities.byId('').id, 'istanbul');
    });

    test('bilinen kimlik doğru şehri verir', () {
      expect(TransitCities.byId('kocaeli').name, 'Kocaeli');
      expect(TransitCities.byId('istanbul').name, 'İstanbul');
    });
  });

  group('Özellik bayrakları', () {
    test('canlı otobüs yalnızca İstanbul’da', () {
      expect(TransitCities.istanbul.hasLiveBus, isTrue);
      // İETT açık servis veriyor, Kocaeli vermiyor — düğme gösterilmemeli.
      expect(TransitCities.kocaeli.hasLiveBus, isFalse);
    });

    test('trafik iki şehirde de var (ayrı servisler)', () {
      // İstanbul: İBB Ulaşım Yönetim Merkezi indeksi.
      expect(TransitCities.istanbul.hasTraffic, isTrue);
      // Kocaeli: Akıllı Şehir Kocaeli anlık yoğunluk servisi.
      expect(TransitCities.kocaeli.hasTraffic, isTrue);
    });

    test('duyuru beslemesi yalnızca İstanbul’da', () {
      // İETT sefer duyurusu servisi veriyor; Kocaeli'de karşılığı yok.
      expect(TransitCities.istanbul.hasAnnouncements, isTrue);
      expect(TransitCities.kocaeli.hasAnnouncements, isFalse);
    });
  });

  group('Lisans atfı', () {
    test('her şehrin atıf metni var', () {
      // CC BY / İBB Açık Veri lisansları atfı ZORUNLU kılıyor; boş kalamaz.
      for (final c in TransitCities.all) {
        expect(c.attribution.trim(), isNotEmpty, reason: '${c.name} atıfsız');
      }
    });

    test('Kocaeli atfı CC BY belirtir', () {
      expect(TransitCities.kocaeli.attribution, contains('CC BY'));
      expect(TransitCities.kocaeli.attribution, contains('Kocaeli'));
    });
  });
}
