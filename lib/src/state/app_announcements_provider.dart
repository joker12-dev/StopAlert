import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_announcement.dart';
import '../services/app_announcements_service.dart';

/// Yenile'ye basınca artar — sağlayıcıya "önbelleği atla" der.
final appAnnouncementsRefreshProvider = StateProvider<int>((_) => 0);

/// Uygulama duyuruları (uzak JSON'dan; en yeni önce).
final appAnnouncementsProvider =
    FutureProvider.autoDispose<List<AppAnnouncement>>((ref) async {
  final n = ref.watch(appAnnouncementsRefreshProvider);
  // autoDispose olmasına rağmen sonuç servis katmanında önbelleklenir.
  ref.keepAlive();
  return AppAnnouncementsService.fetch(force: n > 0);
});

/// En son GÖRÜLEN (okunmuş) en yeni duyurunun kimliği.
///
/// Zil rozetini bu belirler: en yeni duyurunun kimliği bundan farklıysa
/// "okunmamış" var demektir. Duyurular açıldığında en yeni kimlik kaydedilir.
final announcementsSeenProvider =
    AsyncNotifierProvider<AnnouncementsSeen, String?>(AnnouncementsSeen.new);

class AnnouncementsSeen extends AsyncNotifier<String?> {
  static const _key = 'announcements_seen_top_v1';

  @override
  Future<String?> build() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key);
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> markSeen(String? topId) async {
    if (topId == null || topId.isEmpty) return;
    state = AsyncData(topId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, topId);
  }
}

/// Okunmamış duyuru var mı — zil rozeti için.
final hasUnreadAnnouncementsProvider = Provider.autoDispose<bool>((ref) {
  final list = ref.watch(appAnnouncementsProvider).valueOrNull;
  if (list == null || list.isEmpty) return false;
  final seen = ref.watch(announcementsSeenProvider).valueOrNull;
  return list.first.id != seen;
});
