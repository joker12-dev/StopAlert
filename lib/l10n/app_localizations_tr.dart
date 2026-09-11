// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Turkish (`tr`).
class AppLocalizationsTr extends AppLocalizations {
  AppLocalizationsTr([String locale = 'tr']) : super(locale);

  @override
  String get navHome => 'Ana Sayfa';

  @override
  String get navLines => 'Hatlar';

  @override
  String get navStops => 'Duraklar';

  @override
  String get navFavorites => 'Favoriler';

  @override
  String get navProfile => 'Profil';

  @override
  String get homeSearchTitle => 'Nereye ineceksin?';

  @override
  String get homeSearchHint => 'İneceğin durağı veya hattı yaz...';

  @override
  String get homeCurrentLocation => 'Mevcut Konum: ';

  @override
  String get homeYourLocation => 'Konumun';

  @override
  String get homeNearbyStops => 'Yakındaki Duraklar';

  @override
  String get homeStartAlarm => 'Alarm Başlat';

  @override
  String get stopBadge => 'DURAK';

  @override
  String get homeNearbyError => 'Yakındaki duraklar alınamadı.';

  @override
  String get homeLocationOff =>
      'Konum kapalı — yakındaki durakları görmek için konum izni ver.';

  @override
  String get homeFavoriteRoutes => 'Favori Rotalar';

  @override
  String get seeAll => 'Tümü';

  @override
  String get mostUsedLines => 'En Sık Kullanılan Hatlar';

  @override
  String get mostUsedStops => 'En Sık İnilen Duraklar';

  @override
  String get tipMorning =>
      'Sabah yoğunluğu başladı; ineceğin durağa alarmı şimdi kur.';

  @override
  String get tipEvening => 'Akşam saatleri yoğun; alarmını erkenden kur.';

  @override
  String get tipLateNight =>
      'Son seferleri kaçırma; ineceğin durağa alarm kur.';

  @override
  String get tipDefault => 'Uykun gelirse diye — ineceğin durağa alarm kur.';

  @override
  String get categoryBus => 'Otobüs';

  @override
  String get categoryMetrobus => 'Metrobüs';

  @override
  String get categoryMarmaray => 'Marmaray';

  @override
  String get categoryMetro => 'Metro';

  @override
  String get categoryTram => 'Tramvay';

  @override
  String get categoryFerry => 'Vapur';

  @override
  String get actionUnderstood => 'Anladım';

  @override
  String get actionCancel => 'Vazgeç';

  @override
  String get actionSave => 'Kaydet';

  @override
  String get actionContinue => 'Devam et';

  @override
  String get actionClose => 'Kapat';

  @override
  String get settingsTitle => 'Ayarlar';

  @override
  String get appSection => 'UYGULAMA';

  @override
  String get language => 'Dil';

  @override
  String get languageSubtitle => 'Uygulama görüntüleme dili';

  @override
  String get systemDefault => 'Sistem dili';

  @override
  String get ringAlarmLabel => 'ALARM';

  @override
  String get ringApproaching => 'DURAĞINA YAKLAŞTIN!';

  @override
  String ringRemainingDistance(String value) {
    return 'Kalan Mesafe: $value';
  }

  @override
  String get ringActive => 'Alarm aktif';

  @override
  String get ringGetOff => 'İnme zamanı geldi, kapılar açılıyor.';

  @override
  String get ringSlideToStop => 'Alarmı durdurmak için kaydır';

  @override
  String ringSnooze(int minutes) {
    return '$minutes Dakika Ertele';
  }
}
