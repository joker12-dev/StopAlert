/// Türkçe'ye uygun büyük/küçük harf dönüşümü.
///
/// GEREKLİ ÇÜNKÜ Dart'ın `toUpperCase()`'i Unicode'un dilden bağımsız
/// kuralını uygular ve Türkçe'de yanlış sonuç verir:
///
///   'Şişli Mecidiyeköy'.toUpperCase()  →  'ŞIŞLI MECIDIYEKÖY'   (yanlış)
///   trUpper('Şişli Mecidiyeköy')       →  'ŞİŞLİ MECİDİYEKÖY'   (doğru)
///
/// Kural: noktalı `i` büyüğü `İ`, noktasız `ı` büyüğü `I`. Öteki Türkçe
/// harfleri (ğ, ü, ş, ö, ç) Dart zaten doğru çeviriyor.
library;

/// Türkçe kurallarına göre BÜYÜK harf.
String trUpper(String s) =>
    s.replaceAll('i', 'İ').replaceAll('ı', 'I').toUpperCase();

/// Türkçe kurallarına göre küçük harf.
String trLower(String s) =>
    s.replaceAll('I', 'ı').replaceAll('İ', 'i').toLowerCase();
