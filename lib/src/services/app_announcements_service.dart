import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/app_announcement.dart';

/// Uygulama duyurularını uzak bir JSON dosyasından çeker.
///
/// KAYNAK: GitHub'da (ya da herhangi bir statik host'ta) tutulan bir JSON.
/// Geliştirici duyuruları oraya yazar; uygulama açılışta/yenilemede okur.
///
/// Beklenen JSON biçimi (her ikisi de kabul edilir):
/// ```json
/// {
///   "announcements": [
///     {
///       "id": "2026-08-27-bakim",
///       "category": "dikkat",           // uyari | dikkat | bilgi
///       "title": "Planlı bakım",
///       "body": "Bu gece 22:00-23:00 arası canlı konum kesintili olabilir.",
///       "date": "2026-08-27"
///     }
///   ]
/// }
/// ```
/// ya da doğrudan bir dizi: `[ {…}, {…} ]`.
abstract final class AppAnnouncementsService {
  /// Duyuru JSON'unun HAM (raw) adresi.
  ///
  /// ⚠️ BURAYI KENDİ DOSYANLA DEĞİŞTİR. GitHub'da bir depo aç, içine
  /// `announcements.json` koy ve "Raw" adresini buraya yapıştır. Örnek:
  ///   https://raw.githubusercontent.com/KULLANICI/REPO/main/announcements.json
  /// (Firebase Hosting'e koyacaksan onun URL'sini de verebilirsin.)
  static const url =
      'https://raw.githubusercontent.com/joker12-dev/Duyurular/main/duyurular.json';

  /// Ağ isteği bu kadar bekletilir; aşılırsa önbellek/boş liste döner.
  static const _timeout = Duration(seconds: 10);

  /// Aynı oturumda bu süre içinde tekrar sorulursa önbellekten dönülür.
  static const _freshFor = Duration(minutes: 10);

  static List<AppAnnouncement>? _cache;
  static DateTime? lastFetchedAt;

  /// Duyurular (en yeni önce). Ağ yoksa/başarısızsa önbellek ya da boş liste.
  static Future<List<AppAnnouncement>> fetch({bool force = false}) async {
    final cached = _cache;
    if (!force &&
        cached != null &&
        lastFetchedAt != null &&
        DateTime.now().difference(lastFetchedAt!) < _freshFor) {
      return cached;
    }
    try {
      final res = await http.get(Uri.parse(url)).timeout(_timeout);
      if (res.statusCode != 200) return cached ?? const [];
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      final rawList = decoded is Map<String, dynamic>
          ? (decoded['announcements'] ?? decoded['duyurular'] ?? const [])
          : decoded;
      if (rawList is! List) return cached ?? const [];

      final list = <AppAnnouncement>[
        for (final e in rawList)
          if (e is Map<String, dynamic>) AppAnnouncement.fromJson(e),
      ]..removeWhere((a) => a.title.isEmpty && a.body.isEmpty);

      // En yeni önce (tarihi olanlar üstte; tarihsizler sona).
      list.sort((a, b) {
        final da = a.date, db = b.date;
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da);
      });

      _cache = list;
      lastFetchedAt = DateTime.now();
      return list;
    } catch (_) {
      // Ağ/biçim hatası: uygulamayı asla bozma, elde olanı ver.
      return cached ?? const [];
    }
  }
}
