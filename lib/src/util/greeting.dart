/// Saate göre selamlama — ana sayfadaki karşılama satırı.
///
/// Sabit "Merhaba" yerine günün saatini kullanmak uygulamayı kişisel
/// kılıyor; ayrıca gece yarısı alarm kuran kullanıcıya "günaydın" demek
/// tuhaf olurdu.
///
/// Dilimler Türkçe konuşma alışkanlığına göre:
///   05-10 günaydın · 11-14 iyi öğlenler · 15-17 iyi günler
///   18-21 iyi akşamlar · 22-04 iyi geceler
String greetingForHour(int hour) {
  if (hour >= 5 && hour < 11) return 'Günaydın';
  if (hour >= 11 && hour < 15) return 'İyi öğlenler';
  if (hour >= 15 && hour < 18) return 'İyi günler';
  if (hour >= 18 && hour < 22) return 'İyi akşamlar';
  return 'İyi geceler';
}
