import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../util/platform_check.dart';

/// GÜNLÜK yolculuk hatırlatmaları — sabah (işe/okula) ve akşam (iş çıkışı).
///
/// Yerel zamanlanmış bildirimler (sunucu gerektirmez, uçak modunda bile çalışır);
/// her gün aynı saatte tekrarlanır (`DateTimeComponents.time`). Firebase'den
/// gönderilen kampanyalar bunun YERİNE değil, EK olarak kullanılabilir
/// (bkz. PushMessaging — gelen mesajlar Bildirimler geçmişine de düşer).
///
/// Ayarlardan tek anahtarla açılıp kapatılır (varsayılan AÇIK).
abstract final class DailyReminders {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _channelId = 'stopalert_daily_v1';
  static const _enabledKey = 'daily_reminders_enabled_v1';
  static const _morningId = 9200;
  static const _eveningId = 9201;

  static bool _tzReady = false;

  static Future<bool> isEnabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_enabledKey) ?? true;
  }

  static Future<void> setEnabled(bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_enabledKey, value);
    if (value) {
      await schedule();
    } else {
      await cancelAll();
    }
  }

  /// Açılışta çağrılır: açıksa günlük hatırlatmaları (yeniden) kurar.
  static Future<void> init() async {
    if (!isMobileDevice) return;
    if (await isEnabled()) await schedule();
  }

  static Future<void> _ensureTimezone() async {
    if (_tzReady) return;
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Bölge çözülemezse UTC; saat kayabilir ama çökmez.
    }
    _tzReady = true;
  }

  static Future<void> schedule() async {
    if (!isMobileDevice) return;
    await _ensureTimezone();
    await _daily(
      _morningId,
      7,
      45,
      'Günaydın! 🚌',
      'Yola çıkarken ineceğin durağa alarm kur — kaçırmadan, rahatça git.',
    );
    await _daily(
      _eveningId,
      17,
      45,
      'İş çıkışı 🏠',
      'Dönüş yolunda alarmını kur; telefonuna bakmadan yolculuğun tadını çıkar.',
    );
  }

  /// Her gün aynı saatte tekrarlayan tek bir hatırlatma.
  static Future<void> _daily(
      int id, int hour, int minute, String title, String body) async {
    final now = tz.TZDateTime.now(tz.local);
    var when = tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    if (!when.isAfter(now)) when = when.add(const Duration(days: 1));
    try {
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: when,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Günlük hatırlatmalar',
            channelDescription: 'Sabah ve akşam yolculuk hatırlatmaları',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            category: AndroidNotificationCategory.reminder,
            autoCancel: true,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBanner: true,
            presentList: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        // HER GÜN aynı saat.
        matchDateTimeComponents: DateTimeComponents.time,
      );
    } catch (_) {
      // Zamanlama başarısızsa sessiz geç; yardımcı özellik.
    }
  }

  static Future<void> cancelAll() async {
    try {
      await _plugin.cancel(id: _morningId);
      await _plugin.cancel(id: _eveningId);
    } catch (_) {}
  }
}
