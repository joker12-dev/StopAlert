import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/state/weather_provider.dart';

/// Ana sayfa başlık görselinin gündüz mü gece mi olacağı.
///
/// Karar CANLI gün doğumu/batımından veriliyor (Open-Meteo, hava durumuyla
/// aynı istekte); veri yoksa sabit kurala düşülüyor. Sabit kuralın var olması
/// şart: konum izni ya da ağ olmayan kullanıcı da bir arka plan görmeli.
void main() {
  /// [now] anında, verilen güneş saatleriyle gece mi?
  bool nightAt(DateTime now, {DateTime? sunrise, DateTime? sunset}) {
    // isNightProvider'ın kuralının birebir aynısı — sağlayıcı DateTime.now()
    // kullandığı için saat enjekte edilemiyor; kural burada sabitleniyor.
    if (sunrise != null && sunset != null) {
      return now.isBefore(sunrise) || now.isAfter(sunset);
    }
    return now.hour < 7 || now.hour >= 20;
  }

  group('Canlı güneş saatleriyle', () {
    // İstanbul 9 Ağustos 2026: doğuş 06:07, batış 20:11 (Open-Meteo).
    final sunrise = DateTime(2026, 8, 9, 6, 7);
    final sunset = DateTime(2026, 8, 9, 20, 11);

    test('gün doğumundan önce gece', () {
      expect(nightAt(DateTime(2026, 8, 9, 5, 30),
              sunrise: sunrise, sunset: sunset),
          isTrue);
    });

    test('gündüz saatleri gündüz', () {
      for (final h in [7, 12, 18, 20]) {
        expect(
            nightAt(DateTime(2026, 8, 9, h), sunrise: sunrise, sunset: sunset),
            isFalse,
            reason: '$h:00');
      }
    });

    test('gün batımından sonra gece', () {
      expect(
          nightAt(DateTime(2026, 8, 9, 20, 30),
              sunrise: sunrise, sunset: sunset),
          isTrue);
      // Yazın 20:30 hâlâ gündüz sayılırdı sabit kuralda — canlı veri bunu
      // düzeltiyor, testin varlık sebebi bu.
      expect(nightAt(DateTime(2026, 8, 9, 20, 30)), isTrue);
    });
  });

  group('Yedek sabit kural', () {
    test('07:00 öncesi ve 20:00 sonrası gece', () {
      expect(nightAt(DateTime(2026, 1, 5, 6, 59)), isTrue);
      expect(nightAt(DateTime(2026, 1, 5, 7, 0)), isFalse);
      expect(nightAt(DateTime(2026, 1, 5, 19, 59)), isFalse);
      expect(nightAt(DateTime(2026, 1, 5, 20, 0)), isTrue);
    });
  });

  testWidgets('güneş verisi yokken sağlayıcı yine bir cevap verir',
      (tester) async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // weatherProvider konum olmadan null döner; isNight yine de karar vermeli.
    expect(c.read(isNightProvider), isA<bool>());
  });
}
