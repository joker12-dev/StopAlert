import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/util/turkish.dart';

/// Türkçe büyük/küçük harf.
///
/// Dart'ın `toUpperCase()`'i dilden bağımsız Unicode kuralını uygular ve
/// Türkçe'de yanlış sonuç verir: noktalı `i` → noktasız `I`. Durak adları
/// ekranda büyük harfle yazıldığı için hata doğrudan kullanıcıya çıkıyordu.
void main() {
  test('noktalı i büyüğü İ olur', () {
    expect(trUpper('Şişli'), 'ŞİŞLİ');
    expect(trUpper('Mecidiyeköy'), 'MECİDİYEKÖY');
    expect(trUpper('Nasreddin Hoca İlkokulu'), 'NASREDDİN HOCA İLKOKULU');
    // Dart'ın kendi davranışı yanlıştı — gerileme koruması.
    expect('Şişli'.toUpperCase(), isNot('ŞİŞLİ'));
  });

  test('noktasız ı büyüğü I olur', () {
    expect(trUpper('Kadıköy'), 'KADIKÖY');
    expect(trUpper('Sarıyer'), 'SARIYER');
  });

  test('öteki Türkçe harfler bozulmaz', () {
    expect(trUpper('Üsküdar Çağlayan Göztepe'), 'ÜSKÜDAR ÇAĞLAYAN GÖZTEPE');
  });

  test('zaten büyük metin değişmez', () {
    expect(trUpper('KADIKÖY - ÜSKÜDAR'), 'KADIKÖY - ÜSKÜDAR');
  });

  test('küçük harfte I ı, İ i olur', () {
    expect(trLower('KADIKÖY'), 'kadıköy');
    expect(trLower('İSTANBUL'), 'istanbul');
  });
}
