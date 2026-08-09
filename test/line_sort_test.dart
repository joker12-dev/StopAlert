import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/screens/lines_by_type_screen.dart';

/// Hat kodu sıralaması — "Otobüs" sayfasındaki liste düzeni.
///
/// Düz metin sıralaması "100"ü "11"in önüne koyuyordu; 2400 hatlık bir liste
/// böyle okunmuyor. Kod sayı/harf öbeklerine bölünüp sayılar SAYI olarak
/// karşılaştırılır.
void main() {
  List<String> sorted(List<String> codes) =>
      [...codes]..sort(compareLineCodes);

  test('sayılar sayı olarak sıralanır', () {
    expect(sorted(['100', '11', '10', '2', '99']),
        ['2', '10', '11', '99', '100']);
  });

  test('aynı sayının harfli varyantı hemen ardından gelir', () {
    expect(sorted(['10A', '10', '11', '10B']), ['10', '10A', '10B', '11']);
  });

  test('sayıyla başlayanlar harfle başlayanlardan önce', () {
    // "500T" bir otobüs numarası, "E-58" özel halk otobüsü kodu.
    expect(sorted(['E-58', '500T', '34']), ['34', '500T', 'E-58']);
  });

  test('tire ve boşluk sıralamayı bozmaz', () {
    // "E-58" ile "E58" aynı yere düşmeli.
    expect(sorted(['E-59', 'E58', 'E-57']), ['E-57', 'E58', 'E-59']);
  });

  test('harf kodları kendi arasında alfabetik', () {
    expect(sorted(['MK15', 'MK13', 'TF2']), ['MK13', 'MK15', 'TF2']);
  });
}
