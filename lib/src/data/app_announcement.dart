/// Uygulama duyurusu — İETT değil, UYGULAMANIN kendi duyuruları (aksaklık,
/// bakım, güncelleme, bilgilendirme). GitHub'daki bir JSON dosyasından okunur;
/// içeriği geliştirici elle yazar (bkz. [AppAnnouncementsService]).
enum AnnouncementKind {
  /// Kırmızı — aksaklık/sorun (ör. "canlı konum çalışmıyor").
  uyari,

  /// Turuncu — dikkat çekilmesi gereken durum (ör. "planlı bakım").
  dikkat,

  /// Mavi — bilgilendirme (ör. "yeni özellik geldi").
  bilgi;

  /// JSON'daki serbest metni türe çevirir (TR/EN eş anlamlıları kabul eder).
  static AnnouncementKind fromRaw(String? raw) {
    final s = (raw ?? '').trim().toLowerCase();
    switch (s) {
      case 'uyari':
      case 'uyarı':
      case 'warning':
      case 'error':
      case 'critical':
        return AnnouncementKind.uyari;
      case 'dikkat':
      case 'attention':
      case 'caution':
      case 'warn':
        return AnnouncementKind.dikkat;
      default:
        return AnnouncementKind.bilgi;
    }
  }
}

class AppAnnouncement {
  const AppAnnouncement({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    this.date,
  });

  /// Benzersiz kimlik (okundu takibi için). JSON'da yoksa başlık+tarihten üretilir.
  final String id;
  final AnnouncementKind kind;
  final String title;
  final String body;

  /// İsteğe bağlı yayın tarihi ("2026-08-27" veya ISO).
  final DateTime? date;

  factory AppAnnouncement.fromJson(Map<String, dynamic> j) {
    final title = (j['title'] ?? j['baslik'] ?? '').toString().trim();
    final body = (j['body'] ?? j['aciklama'] ?? j['açıklama'] ?? '')
        .toString()
        .trim();
    final rawDate = (j['date'] ?? j['tarih'])?.toString();
    final date = rawDate == null ? null : DateTime.tryParse(rawDate.trim());
    final id = (j['id'] ?? '').toString().trim();
    return AppAnnouncement(
      id: id.isNotEmpty ? id : '${rawDate ?? ''}|$title',
      kind: AnnouncementKind.fromRaw(
          (j['category'] ?? j['kategori'] ?? j['kind'])?.toString()),
      title: title,
      body: body,
      date: date,
    );
  }
}
