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

  // Her SAAT DİLİMİNE ayrı bildirim id'si (9100 + saat). Eskiden tek id (9101)
  // vardı ve her yeni yolculuk bekleyen hatırlatmayı EZİYORDU: sabah–akşam
  // gidip gelen kullanıcıda akşam yolculuğu sabahki hatırlatmayı iptal ediyor,
  // hatırlatma sürekli erteleniyordu. Artık sabah (08:xx) ve akşam (18:xx)
  // ayrı id'lerde birlikte yaşar.
  static const _baseId = 9100;
  static const _legacyId = 9101;
  static const _maxSlots = 4; // en fazla 4 farklı saat dilimi tutulur
  static const _prefsKey = 'journey_reminders_v2';
  static const _legacyPrefsKey = 'journey_reminder_v1';
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
  ///
  /// Hatırlatmalar SAAT DİLİMİNE göre saklanır (anahtar = yolculuğun saati),
  /// böylece sabah ve akşam yolculukları AYRI hatırlatmalar olur ve birbirini
  /// ezmez.
  static Future<void> onJourneyStarted(JourneyPayload payload) async {
    if (!isMobileDevice) return;
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
      'ts': now.millisecondsSinceEpoch,
    };

    final map = await _loadMap(prefs);
    map['${now.hour}'] = record;
    // En fazla _maxSlots farklı saat: fazlaysa EN ESKİYİ (ts) at + iptal et.
    if (map.length > _maxSlots) {
      final entries = map.entries.toList()
        ..sort((a, b) => ((a.value['ts'] as num?)?.toInt() ?? 0)
            .compareTo((b.value['ts'] as num?)?.toInt() ?? 0));
      while (map.length > _maxSlots && entries.isNotEmpty) {
        final oldest = entries.removeAt(0);
        map.remove(oldest.key);
        final h = int.tryParse(oldest.key);
        if (h != null) {
          try {
            await _plugin.cancel(id: _baseId + h);
          } catch (_) {}
        }
      }
    }
    await prefs.setString(_prefsKey, jsonEncode(map));
    // v1 tek-kayıt biçiminden geçiş: eski kaydı ve eski tek id'yi temizle.
    await prefs.remove(_legacyPrefsKey);
    try {
      await _plugin.cancel(id: _legacyId);
    } catch (_) {}

    if (!(prefs.getBool('journey_reminder_enabled_v1') ?? true)) return;
    await _schedule(record, now);
  }

  /// Kayıtlı hatırlatmaları saat→kayıt haritası olarak yükler (v1 göçü dahil).
  static Future<Map<String, Map<String, dynamic>>> _loadMap(
      SharedPreferences prefs) async {
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        return m.map(
            (k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
      } catch (_) {}
    }
    // Eski tek kayıt → tek elemanlı harita.
    final old = prefs.getString(_legacyPrefsKey);
    if (old != null && old.isNotEmpty) {
      try {
        final r = Map<String, dynamic>.from(jsonDecode(old) as Map);
        final h = (r['hour'] as num?)?.toInt() ?? 8;
        return {'$h': r};
      } catch (_) {}
    }
    return {};
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
        id: _baseId + (hour % 24),
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
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentSound: true,
            presentBanner: true,
            presentList: true,
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

  /// EN SON kurulan hatırlatma bilgisi (varsa) — ayarlar ekranı özeti gösterir.
  static Future<Map<String, dynamic>?> saved() async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _loadMap(prefs);
    if (map.isEmpty) return null;
    final list = map.values.toList()
      ..sort((a, b) => ((b['ts'] as num?)?.toInt() ?? 0)
          .compareTo((a['ts'] as num?)?.toInt() ?? 0));
    return list.first;
  }

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('journey_reminder_enabled_v1') ?? true;
  }

  /// Ayarlardan aç/kapat. Kapatınca bekleyen TÜM hatırlatmalar iptal edilir;
  /// açınca kayıtlı saat dilimlerinin HEPSİ yeniden kurulur.
  static Future<void> setEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('journey_reminder_enabled_v1', value);
    if (!value) {
      await cancel();
      return;
    }
    final map = await _loadMap(prefs);
    final now = DateTime.now();
    for (final r in map.values) {
      await _schedule(r, now);
    }
  }

  /// Bekleyen tüm hatırlatmaları iptal et (kayıtları korur).
  static Future<void> cancel() async {
    final prefs = await SharedPreferences.getInstance();
    final map = await _loadMap(prefs);
    for (final k in map.keys) {
      final h = int.tryParse(k);
      if (h == null) continue;
      try {
        await _plugin.cancel(id: _baseId + h);
      } catch (_) {}
    }
    try {
      await _plugin.cancel(id: _legacyId);
    } catch (_) {}
  }
}
