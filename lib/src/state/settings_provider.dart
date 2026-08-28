import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/alarm_sound.dart';

import '../state/journey_provider.dart';

import '../util/haptics.dart';
import '../data/search_filter.dart';
import '../util/map_style.dart';

/// Kalıcı kullanıcı ayarları (cihazda SharedPreferences).
///
/// "Gerçek" Ayarlar sayfasını besler: titreşim, alarm sesi, erteleme süresi ve
/// alarm kurulum ekranının varsayılan tetikleme tercihleri burada tutulur.
class AppSettings {
  const AppSettings({
    this.nickname = 'Yolcu',
    this.vibration = true,
    this.alarmSound = 'Radar', // = alarmSounds[0]
    this.snoozeMinutes = 5,
    this.defaultTriggerMode = 1, // 0 = kalan durak, 1 = kalan mesafe
    this.defaultDistanceIndex = 1, // 500m
    this.defaultStopsIndex = 1, // 2 durak
    this.contributeToCloud = false, // KVKK: anonim kalabalık öğrenmeye katkı
    this.mapStyle = 'sokak', // MapTileStyle adi (varsayilan: Sokak/MapTiler)
    this.searchFilter = 'tumu', // SearchFilter.id (varsayilan: Tumu)
  });

  /// Kullanıcının takma adı (Profil + ana sayfa selamlaması).
  final String nickname;
  final bool vibration;

  /// KVKK rızası: durak-arası sürelerin ANONİM olarak buluttaki ortak
  /// modele katkı vermesine izin ver (varsayılan kapalı; kullanıcı açar).
  final bool contributeToCloud;

  /// Harita stili — [MapTileStyle] adı ('gece' | 'canli' | 'uydu' | 'sade').
  /// Eski sürümlerden gelen 'dark'/'light' değerleri de desteklenir.
  final String mapStyle;

  /// Kayıtlı değeri (eski 'dark'/'light' dâhil) stil enum'una çevirir.
  MapTileStyle get mapTileStyle {
    final s = switch (mapStyle) {
      'light' => MapTileStyle.sade,
      'dark' => MapTileStyle.gece,
      _ => MapTileStyle.fromName(mapStyle),
    };
    // MapTiler anahtarı yoksa "Sokak" kullanılamaz → OSM standart'a düş.
    if (s == MapTileStyle.sokak && !AppMapStyle.hasMaptiler) {
      return MapTileStyle.standart;
    }
    return s;
  }

  /// Kullanıcı-dostu harita stili etiketi.
  String get mapStyleLabel => mapTileStyle.label;

  /// Arama ekranındaki tür süzgeci ([SearchFilter.id]).
  ///
  /// KALICI: kullanıcı "Otobüs"ü seçtiyse uygulamayı kapatıp açtığında
  /// yine otobüste kalır — her açılışta seçimini tekrarlatmak sinir bozucu.
  final String searchFilter;

  SearchFilter get searchFilterValue => SearchFilter.fromId(searchFilter);
  final String alarmSound;
  final int snoozeMinutes;
  final int defaultTriggerMode;
  final int defaultDistanceIndex;
  final int defaultStopsIndex;

  /// Seçilebilir alarm sesleri (isimler; res/raw eşlemesi Faz 2'de genişler).
  /// Seçilebilir alarm sesleri — TEK KAYNAK [AlarmSound.all].
  ///
  /// Burada ayrı bir liste tutmak iki yerin ayrışmasına yol açıyordu:
  /// ayarlarda görünen "Dalga" ve "Sinyal" seçeneklerinin dosyası yoktu.
  static List<String> get alarmSounds =>
      [for (final s in AlarmSound.all) s.label];

  /// Seçilebilir erteleme süreleri (dakika).
  static const snoozeOptions = [3, 5, 10];

  /// Alarm tetikleme eşikleri — TEK kaynak (alarm kurulum + ayarlar ortak).
  static const distanceLabels = ['250m', '500m', '1km', '2km'];
  static const distanceMeters = [250.0, 500.0, 1000.0, 2000.0];
  static const stopLabels = ['1 durak', '2 durak', '3 durak'];
  static const stopValues = [1, 2, 3];

  /// Varsayılan tetikleyicinin okunabilir etiketi ("500m kala" / "2 durak kala").
  String get defaultTriggerLabel {
    if (defaultTriggerMode == 0) {
      final i = defaultStopsIndex.clamp(0, stopLabels.length - 1);
      return '${stopLabels[i]} kala';
    }
    final i = defaultDistanceIndex.clamp(0, distanceLabels.length - 1);
    return '${distanceLabels[i]} kala';
  }

  AppSettings copyWith({
    String? nickname,
    bool? vibration,
    String? alarmSound,
    int? snoozeMinutes,
    int? defaultTriggerMode,
    int? defaultDistanceIndex,
    int? defaultStopsIndex,
    bool? contributeToCloud,
    String? mapStyle,
    String? searchFilter,
  }) =>
      AppSettings(
        nickname: nickname ?? this.nickname,
        vibration: vibration ?? this.vibration,
        alarmSound: alarmSound ?? this.alarmSound,
        snoozeMinutes: snoozeMinutes ?? this.snoozeMinutes,
        defaultTriggerMode: defaultTriggerMode ?? this.defaultTriggerMode,
        defaultDistanceIndex: defaultDistanceIndex ?? this.defaultDistanceIndex,
        defaultStopsIndex: defaultStopsIndex ?? this.defaultStopsIndex,
        contributeToCloud: contributeToCloud ?? this.contributeToCloud,
        mapStyle: mapStyle ?? this.mapStyle,
        searchFilter: searchFilter ?? this.searchFilter,
      );

  Map<String, dynamic> toMap() => {
        'nickname': nickname,
        'vibration': vibration,
        'alarmSound': alarmSound,
        'snoozeMinutes': snoozeMinutes,
        'defaultTriggerMode': defaultTriggerMode,
        'defaultDistanceIndex': defaultDistanceIndex,
        'defaultStopsIndex': defaultStopsIndex,
        'contributeToCloud': contributeToCloud,
        'mapStyle': mapStyle,
        'searchFilter': searchFilter,
      };

  factory AppSettings.fromMap(Map<String, dynamic> m) => AppSettings(
        nickname: (m['nickname'] as String?)?.trim().isNotEmpty == true
            ? (m['nickname'] as String).trim()
            : 'Yolcu',
        vibration: m['vibration'] as bool? ?? true,
        alarmSound: m['alarmSound'] as String? ?? alarmSounds[0],
        snoozeMinutes: (m['snoozeMinutes'] as num?)?.toInt() ?? 5,
        defaultTriggerMode: (m['defaultTriggerMode'] as num?)?.toInt() ?? 1,
        defaultDistanceIndex: (m['defaultDistanceIndex'] as num?)?.toInt() ?? 1,
        defaultStopsIndex: (m['defaultStopsIndex'] as num?)?.toInt() ?? 1,
        contributeToCloud: m['contributeToCloud'] as bool? ?? false,
        mapStyle: m['mapStyle'] as String? ?? 'canli',
        searchFilter: m['searchFilter'] as String? ?? 'tumu',
      );
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);

class SettingsNotifier extends AsyncNotifier<AppSettings> {
  static const _prefsKey = 'app_settings_v1';

  @override
  Future<AppSettings> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    AppSettings settings;
    if (raw == null || raw.isEmpty) {
      settings = const AppSettings();
    } else {
      try {
        settings = AppSettings.fromMap(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {
        settings = const AppSettings();
      }
    }
    // Statik katmanları kullanıcı tercihine bağla.
    Haptics.enabled = settings.vibration;
    AppMapStyle.style = settings.mapTileStyle;
    return settings;
  }

  Future<void> _persist(AppSettings next) async {
    state = AsyncData(next);
    Haptics.enabled = next.vibration;
    AppMapStyle.style = next.mapTileStyle;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(next.toMap()));
    // Buluta da yaz: kullanıcı ikinci telefonundan hesabına girdiğinde takma
    // adı ve alarm ayarları da gelsin — favoriler zaten geliyordu, ayarlar
    // gelmeyince hesabın yarısı taşınmış oluyordu.
    await ref.read(profileRepositoryProvider).saveSettings(next.toMap());
  }

  /// Buluttaki ayarları cihaza uygula (giriş sonrası).
  ///
  /// Yalnızca giriş anında çağrılır; her açılışta çekmek, çevrimdışıyken
  /// yapılan yerel değişikliği eski bulut kopyasıyla ezerdi.
  Future<void> applyFromCloud(Map<String, dynamic> map) async {
    try {
      await _persist(AppSettings.fromMap(map));
    } catch (_) {
      // Bozuk kayıt: yerel ayarlar olduğu gibi kalır.
    }
  }

  AppSettings get _current => state.valueOrNull ?? const AppSettings();

  Future<void> setNickname(String value) {
    final trimmed = value.trim();
    return _persist(_current.copyWith(
        nickname: trimmed.isEmpty ? 'Yolcu' : trimmed));
  }

  Future<void> setVibration(bool value) =>
      _persist(_current.copyWith(vibration: value));

  Future<void> setAlarmSound(String value) =>
      _persist(_current.copyWith(alarmSound: value));

  Future<void> setSnoozeMinutes(int value) =>
      _persist(_current.copyWith(snoozeMinutes: value));

  Future<void> setDefaultTrigger({
    int? mode,
    int? distanceIndex,
    int? stopsIndex,
  }) =>
      _persist(_current.copyWith(
        defaultTriggerMode: mode,
        defaultDistanceIndex: distanceIndex,
        defaultStopsIndex: stopsIndex,
      ));

  Future<void> setContributeToCloud(bool value) =>
      _persist(_current.copyWith(contributeToCloud: value));

  Future<void> setMapStyle(String value) =>
      _persist(_current.copyWith(mapStyle: value));

  Future<void> setSearchFilter(SearchFilter value) =>
      _persist(_current.copyWith(searchFilter: value.id));
}
