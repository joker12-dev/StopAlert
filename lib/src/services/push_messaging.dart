import 'package:firebase_messaging/firebase_messaging.dart';

import '../state/notification_history_provider.dart';
import '../util/platform_check.dart';
import 'alarm_notifications.dart';

/// ARKA PLAN / KAPALI uygulama mesaj işleyicisi (top-level ŞART).
///
/// Ayrı bir isolate'te çalışır; yalnızca geçmişe yazar (shared_preferences
/// arka planda çalışır). Bildirimin kendisini işletim sistemi zaten gösterir.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  final n = message.notification;
  await NotificationHistoryStore.add(
    id: message.messageId,
    title: n?.title ?? '${message.data['title'] ?? 'Bildirim'}',
    body: n?.body ?? '${message.data['body'] ?? ''}',
  );
}

/// Firebase Cloud Messaging entegrasyonu.
///
/// Gönderdiğimiz push mesajları uygulama içi "Bildirimler" geçmişine düşer
/// (okundu/okunmadı). Uygulama AÇIKKEN gelen mesaj OS tarafından otomatik
/// gösterilmez → yerel bildirim olarak biz gösteririz.
///
/// NOT: Mesajların gelmesi için Firebase Console'da Cloud Messaging etkin
/// olmalı; iOS'ta ayrıca APNs anahtarı + "Push Notifications" yetkisi gerekir.
abstract final class PushMessaging {
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited || !isMobileDevice) return;
    _inited = true;
    try {
      final fm = FirebaseMessaging.instance;
      await fm.requestPermission();

      FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);

      // FOREGROUND: geçmişe yaz + yerel bildirim göster.
      FirebaseMessaging.onMessage.listen((m) async {
        final title = _title(m);
        final body = _body(m);
        await NotificationHistoryStore.add(
            id: m.messageId, title: title, body: body);
        await AlarmNotifications.showInfo(
          id: _safeId(m.messageId),
          title: title,
          body: body,
        );
      });

      // Kullanıcı bildirime dokunup uygulamayı AÇTIĞINDA: geçmişe yaz.
      FirebaseMessaging.onMessageOpenedApp.listen((m) async {
        await NotificationHistoryStore.add(
            id: m.messageId, title: _title(m), body: _body(m));
      });

      // Uygulama KAPALIYKEN bildirimle açıldıysa: ilk mesajı geçmişe al.
      final initial = await fm.getInitialMessage();
      if (initial != null) {
        await NotificationHistoryStore.add(
            id: initial.messageId,
            title: _title(initial),
            body: _body(initial));
      }
    } catch (_) {
      // FCM kurulmadıysa (Console/APNs eksik) uygulama normal çalışmaya devam.
    }
  }

  static String _title(RemoteMessage m) =>
      m.notification?.title ?? '${m.data['title'] ?? 'Bildirim'}';

  static String _body(RemoteMessage m) =>
      m.notification?.body ?? '${m.data['body'] ?? ''}';

  static int _safeId(String? messageId) =>
      (messageId?.hashCode ?? DateTime.now().millisecondsSinceEpoch) &
      0x7fffffff;
}
