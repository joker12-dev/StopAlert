import 'dart:typed_data';

import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/alarm_sound.dart';

import '../util/platform_check.dart';

/// Tam ekran, kullanıcı kapatana kadar çalan durak alarmı bildirimi.
///
/// - Kanal: max önem, USAGE_ALARM ses özniteliği (sessize alınmış medya
///   sesinden etkilenmez), özel sentez alarm sesi (res/raw/stopalert_alarm).
/// - FLAG_INSISTENT (4): SES, bildirim kaldırılana KADAR döngüde.
/// - fullScreenIntent: telefon kilitliyken ekranı açıp uygulamayı öne getirir
///   (MainActivity showWhenLocked/turnScreenOn ile birlikte).
///
/// TİTREŞİM bilerek bu kanalda KAPALIDIR: Android'de kanal titreşimi kanal
/// oluşturulurken kilitlenir (sonradan değiştirilemez) ve bazı OEM'lerde
/// insistent titreşim iptal edilince takılı kalır. Bunun yerine titreşim
/// tamamen uygulama içinde (AlarmRingingScreen `_buzz`) yönetilir; böylece
/// "Titreşim" ayarı anında etkiler ve alarm durdurulunca titreşim de anında
/// kesilir.
class AlarmNotifications {
  static const _alarmId = 9001;

  /// Android kanal ayarlarını İLK oluşturmadaki haliyle dondurur. v3: titreşimi
  /// KANAL düzeyinde kapatan taze kanal (v2 titreşimle kilitlenmiş olabilir).
  static const _channelId = 'stopalert_alarm_v3';
  static const _legacyChannelIds = [
    'stopalert_alarm',
    'stopalert_alarm_v2',
    'stopalert_alarm_yedek',
  ];

  /// Özel ses kurulamazsa (bozuk kaynak vb.) alarmı asla sessiz bırakma:
  /// varsayılan sesli ayrı bir yedek kanaldan çal.
  static const _fallbackChannelId = 'stopalert_alarm_yedek_v3';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  /// Kullanıcının seçtiği alarm sesinin kaynağı.
  ///
  /// Ayarlardan okunur (arka plan izolatında Riverpod yok, doğrudan
  /// SharedPreferences). Okunamazsa varsayılana düşer — alarm asla sessiz
  /// kalmamalı.
  static AlarmSound _sound = AlarmSound.all.first;

  static String get _soundResource => _sound.resource;

  /// ANDROID KANALI SESİ DONDURUR: ses değişince kanal kimliği de değişmeli,
  /// yoksa sistem eski sesi çalmaya devam eder.
  ///
  /// Sistem sesleri için kimlik ADRESTEN türetilir; iki sistem seçeneği de
  /// aynı `resource` değerini taşıyor ve tek kimlikte toplanırlarsa kanal
  /// ilk seçilen sesi dondurup ötekine geçmiyordu.
  static String get _soundChannelId {
    final key = _sound.source == AlarmSoundSource.system
        ? 'sys_${_sound.systemUri.split('/').last}'
        : _sound.resource;
    return '${_channelId}_$key';
  }

  /// Bildirim kanalının çalacağı ses.
  static AndroidNotificationSound? _androidSound(String resource) {
    if (_sound.source == AlarmSoundSource.system &&
        _sound.systemUri.isNotEmpty) {
      // CİHAZIN KENDİ SESİ: dosya taşımıyoruz, sistemin adresini veriyoruz.
      return UriAndroidNotificationSound(_sound.systemUri);
    }
    return RawResourceAndroidNotificationSound(resource);
  }

  static Future<void> _loadSoundChoice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('app_settings_v1');
      if (raw == null || raw.isEmpty) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      _sound = AlarmSound.byLabel(map['alarmSound'] as String?);
    } catch (_) {
      // Bozuk ayar: varsayılan ses.
    }
  }

  static Future<void> init() async {
    if (!isMobileDevice || _initialized) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      // İZİN BURADA İSTENMEZ: uygulamanın kendi "Başlamadan Önce" kapısı
      // gerekçesiyle birlikte soruyor. Açılışta habersiz sistem penceresi
      // çıkarsa kullanıcı neden sorulduğunu bilmeden reddediyor.
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestSoundPermission: false,
        requestBadgePermission: false,
      ),
    );
    await _plugin.initialize(settings: settings);
    await _loadSoundChoice();
    // Donmuş eski kanalları temizle; kullanıcı kanal ayarını kaybeder ama
    // alarmın gerçekten çalması bundan önemlidir. (Kanal kavramı Android'e
    // özgü; iOS'ta karşılığı yok.)
    if (isAndroidDevice) {
      try {
        final android = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        for (final id in _legacyChannelIds) {
          await android?.deleteNotificationChannel(channelId: id);
        }
      } catch (_) {}
    }
    _initialized = true;
  }

  /// iOS bildirim davranışı — ALARM.
  ///
  /// Android'in FLAG_INSISTENT ses döngüsünün iOS'ta karşılığı YOK; en yakını
  /// "zaman duyarlı" kesinti düzeyi (Odak modlarını delebilir). Sessiz/Rahatsız
  /// Etme'yi de delmek için Apple'dan Critical Alerts entitlement'ı gerekir.
  ///
  /// ÖZEL ALARM SESİ: iOS'ta bildirim sesi UYGULAMA PAKETİNDE olmak zorunda —
  /// Flutter assets yetmez. Xcode'da Runner hedefine bir `.caf` eklendiğinde
  /// buraya `sound: 'dosya.caf'` yazılır; o zamana kadar varsayılan bildirim
  /// sesi çalar.
  static const _darwinAlarm = DarwinNotificationDetails(
    presentAlert: true,
    presentSound: true,
    presentBanner: true,
    presentList: true,
    // iOS bildirim sesi: uygulama paketine EKLENEN dosya (Flutter assets değil).
    // wav geçerli, mp3 GEÇMEZ, ≤30 sn. Dosya Xcode'da Runner'a eklenene kadar
    // iOS sessizce varsayılan sese düşer (zararsız).
    sound: 'stopalert_alarm.wav',
    interruptionLevel: InterruptionLevel.timeSensitive,
  );

  /// iOS bildirim davranışı — bilgi/duyuru (alarm değil).
  static const _darwinInfo = DarwinNotificationDetails(
    presentAlert: true,
    presentSound: true,
    presentBanner: true,
    presentList: true,
  );

  static AndroidNotificationDetails _details({
    required bool customSound,
    String soundResource = AlarmSound.fallback,
  }) {
    return AndroidNotificationDetails(
      customSound ? _soundChannelId : _fallbackChannelId,
      'Durak Alarmı',
      channelDescription:
          'İneceğin durağa yaklaşınca çalan yüksek öncelikli alarm',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: true,
      playSound: true,
      // Kullanıcının SEÇTİĞİ ses. Eskiden seçim hiç okunmuyordu ve dört
      // seçenek de aynı kaynağı çalıyordu (bkz. AlarmSound).
      sound: customSound ? _androidSound(soundResource) : null,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      // Titreşim KANAL düzeyinde kapalı: uygulama içinde (AlarmRingingScreen)
      // yönetilir — böylece ayar anında etkiler ve durdurunca anında kesilir.
      enableVibration: false,
      vibrationPattern: null,
      // FLAG_INSISTENT = 4: bildirim kapatılana kadar SES döngüde.
      additionalFlags: Int32List.fromList(const [4]),
      ongoing: true,
      autoCancel: false,
      visibility: NotificationVisibility.public,
      ticker: 'Durağına yaklaştın',
    );
  }

  /// Alarmı çal: tam ekran + sürekli ses. Asla sessizce başarısız olmaz: özel
  /// sesli kanal kurulamazsa varsayılan sesli yedek kanala düşer. (Titreşim
  /// uygulama içinde yönetilir; bkz. sınıf açıklaması.)
  static Future<void> showAlarm({
    required String stopName,
    required String body,
  }) async {
    if (!isMobileDevice) return;
    await init();
    try {
      await _plugin.show(
        id: _alarmId,
        title: 'DURAĞINA YAKLAŞTIN',
        body: '$stopName — $body',
        notificationDetails: NotificationDetails(
          android:
              _details(customSound: true, soundResource: _soundResource),
          iOS: _darwinAlarm,
        ),
      );
    } catch (_) {
      try {
        await _plugin.show(
          id: _alarmId,
          title: 'DURAĞINA YAKLAŞTIN',
          body: '$stopName — $body',
          notificationDetails: NotificationDetails(
            android: _details(customSound: false),
            iOS: _darwinAlarm,
          ),
        );
      } catch (_) {}
    }
  }

  /// Alarmı sustur (bildirimi kaldırınca insistent döngü de durur).
  static Future<void> cancelAlarm() async {
    if (!isMobileDevice) return;
    await init();
    await _plugin.cancel(id: _alarmId);
  }

  /// Bilgi/duyuru bildirimi (Firebase Messaging FOREGROUND mesajları için).
  ///
  /// Alarmdan AYRI, sıradan öncelikli kanal: ses çalar ama tam ekran/insistent
  /// değil. Uygulama açıkken FCM bildirimi otomatik gösterilmez; bunu çağırırız.
  static Future<void> showInfo({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!isMobileDevice) return;
    await init();
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'stopalert_push_v1',
            'Bildirimler',
            channelDescription: 'Uygulama duyuruları ve bildirimleri',
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            visibility: NotificationVisibility.public,
          ),
          iOS: _darwinInfo,
        ),
      );
    } catch (_) {}
  }
}
