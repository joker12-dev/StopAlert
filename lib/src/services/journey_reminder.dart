import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/journey_payload.dart';
import '../util/platform_check.dart';

/// Kullanıcının ALIŞKANLIĞINI hatırlatan bildirim.
///
/// Gözlem şu: aynı yolculuk her gün aynı saatte tekrarlanıyor. Kullanıcı sabah
/// 08:00'de "Kadıköy → Taksim" alarmı kurduysa ertesi sabah aynı saatte
/// muhtemelen yine kuracak. Bildirim o anı yakalar ve tek dokunuşla alarmı
/// kurdurur.
///
/// KAPSAM: şimdilik yalnızca HATIRLATMA. Alarmı kendiliğinden kurmak (kullanıcı
/// uygulamayı hiç açmadan) premium özellik olarak planlanıyor; buradaki kayıt
/// yapısı ona da yetecek şekilde tutuluyor.
///
/// Tek bir bekleyen hatırlatma vardır: her yeni yolculuk öncekini değiştirir.
/// Böylece kullanıcı rotasını değiştirdiğinde eski rota hatırlatılmaz.
class JourneyReminder {
  const JourneyReminder._();

  static const _notificationId = 9101;
  static const _prefsKey = 'journey_reminder_v1';
  static const _channelId = 'stopalert_reminder_v1';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _tzReady = false;

  static Future<void> _ensureTimezone() async {
    if (_tzReady) return;
    tzdata.initializeTimeZones();
    try {
      // Cihazın saat dilimi: sabit bir bölge gömmek yurt dışındaki kullanıcıya
      // yanlış saatte bildirim atardı.
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Bölge çözülemezse UTC kalır; hatırlatma saati kayabilir ama sistem
      // çökmez. Alarmın kendisi bundan etkilenmez.
    }
    _tzReady = true;
  }

  /// Yolculuk başlarken çağrılır: aynı saat için YARIN hatırlatma kurar.
  static Future<void> onJourneyStarted(JourneyPayload payload) async {
    if (!isAndroidDevice) return;
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();

    final record = {
      'hour': now.hour,
      'minute': now.minute,
      'lineId': payload.line.id,
      'lineCode': payload.line.code,
      'boardingStopId': payload.boardingStopId,
      'targetStopId': payload.targetStopId,
      'targetStopName': payload.targetStopName,
      'boardingStopName': _stopName(payload, payload.boardingStopId),
    };
    await prefs.setString(_prefsKey, jsonEncode(record));

    if (!(prefs.getBool('journey_reminder_enabled_v1') ?? true)) return;
    await _schedule(record, now);
  }

  static String _stopName(JourneyPayload p, String stopId) {
    for (final s in p.line.stops) {
      if (s.id == stopId) return s.name;
    }
    return '';
  }

  static Future<void> _schedule(
      Map<String, dynamic> record, DateTime from) async {
    await _ensureTimezone();
    final hour = (record['hour'] as num?)?.toInt() ?? 8;
    final minute = (record['minute'] as num?)?.toInt() ?? 0;
    final code = '${record['lineCode'] ?? ''}';
    final boarding = '${record['boardingStopName'] ?? ''}';
    final target = '${record['targetStopName'] ?? ''}';

    // YARIN aynı saat. Her yolculuk bunu yeniden kurduğu için tek bir
    // bekleyen hatırlatma olur.
    final next = tz.TZDateTime.local(
      from.year,
      from.month,
      from.day,
      hour,
      minute,
    ).add(const Duration(days: 1));

    final route = [boarding, target].where((s) => s.isNotEmpty).join(' → ');

    try {
      await _plugin.zonedSchedule(
        id: _notificationId,
        title: code.isEmpty ? 'Alarmını kur' : '$code · alarmını kur',
        body: route.isEmpty
            ? 'Dün bu saatte bir alarm kurmuştun.'
            : '$route — dokun, alarmı hazırlayayım.',
        scheduledDate: next,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            'Yolculuk hatırlatması',
            channelDescription:
                'Her gün aynı saatte kurduğun alarmı hatırlatır',
            // ALARM DEĞİL: bu yalnızca bir hatırlatma. Yüksek öncelik ya da
            // tam ekran kullanmak, gerçek durak alarmıyla karışmasına yol
            // açardı — kullanıcı ikisini ayırt edebilmeli.
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            category: AndroidNotificationCategory.reminder,
            autoCancel: true,
          ),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: jsonEncode(record),
      );
    } catch (_) {
      // Zamanlama başarısızsa sessizce geç: hatırlatma yardımcı bir özellik,
      // alarm akışını hiçbir koşulda etkilememeli.
    }
  }

  /// Kayıtlı hatırlatma bilgisi (varsa) — ayarlar ekranı gösterir.
  static Future<Map<String, dynamic>?> saved() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('journey_reminder_enabled_v1') ?? true;
  }

  /// Ayarlardan aç/kapat. Kapatınca bekleyen hatırlatma da iptal edilir.
  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('journey_reminder_enabled_v1', value);
    if (!value) {
      await cancel();
      return;
    }
    final record = await saved();
    if (record != null) await _schedule(record, DateTime.now());
  }

  static Future<void> cancel() async {
    try {
      await _plugin.cancel(id: _notificationId);
    } catch (_) {}
  }
}
