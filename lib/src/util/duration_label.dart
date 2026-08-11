/// Süreleri KONUŞULDUĞU gibi yazar.
///
/// "75 dk" teknik olarak doğru ama kimse öyle düşünmüyor; yolcu "bir buçuk
/// saat" diye planlıyor. Bir saati aşan her süre saat + dakika olarak yazılır.
library;

/// [minutes] dakikayı okunur etikete çevirir ("1 sa 15 dk").
///
/// Sıfır ve altı "şimdi" değildir — çağıran bağlama göre karar verir; burada
/// yalnızca biçim var.
String minutesLabel(int minutes) {
  if (minutes < 60) return '$minutes dk';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  // Tam saatte "2 sa 0 dk" demek gereksiz gürültü.
  return m == 0 ? '$h sa' : '$h sa $m dk';
}

/// Saniyeden etiket — dakikaya YUVARLAYARAK.
String secondsLabel(int seconds) => minutesLabel((seconds / 60).round());
