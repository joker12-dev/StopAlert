import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/transit_city.dart';
import '../services/location_service.dart';
import '../util/platform_check.dart';

/// Aktif şehir — hangi veri paketinin açık olduğunu belirler.
///
/// Seçim önceliği:
///   1. Kullanıcı elle seçtiyse O geçerlidir (kalıcı, bir daha sorulmaz).
///   2. Yoksa konumdan tahmin edilir (bkz. [TransitCities.forLocation]).
///   3. Konum da yoksa İstanbul.
///
/// Otomatik tahmin YALNIZCA elle seçim yokken çalışır: kullanıcı Kocaeli'yi
/// seçip İstanbul'a gittiğinde seçimi altından kaymamalı.
final cityProvider =
    AsyncNotifierProvider<CityNotifier, TransitCity>(CityNotifier.new);

class CityNotifier extends AsyncNotifier<TransitCity> {
  static const _manualKey = 'transit_city_manual_v1';

  @override
  Future<TransitCity> build() async {
    final prefs = await SharedPreferences.getInstance();
    final manual = prefs.getString(_manualKey);
    if (manual != null && manual.isNotEmpty) {
      return TransitCities.byId(manual);
    }
    return _detectFromLocation();
  }

  /// Konumdan şehir tahmini. İzin İSTEMEZ — yalnızca zaten verilmişse okur;
  /// aksi halde İstanbul'a düşer ve izin kapısı geçildikten sonra
  /// [refreshFromLocation] ile tekrar denenir.
  Future<TransitCity> _detectFromLocation() async {
    if (!isMobileDevice) return TransitCities.fallback;
    try {
      final pos = await LocationService().currentLocationIfGranted();
      if (pos == null) return TransitCities.fallback;
      return TransitCities.forLocation(pos.latitude, pos.longitude);
    } catch (_) {
      return TransitCities.fallback;
    }
  }

  /// İzin verildikten sonra şehri konumdan yeniden belirle (elle seçim
  /// yapılmışsa dokunulmaz).
  Future<void> refreshFromLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final manual = prefs.getString(_manualKey);
    if (manual != null && manual.isNotEmpty) return;
    state = AsyncData(await _detectFromLocation());
  }

  /// Kullanıcı şehri elle seçti — kalıcı olarak sabitlenir.
  Future<void> select(TransitCity city) async {
    state = AsyncData(city);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_manualKey, city.id);
  }

  /// Elle seçimi kaldır: tekrar konumdan belirlensin.
  Future<void> useAutomatic() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_manualKey);
    state = const AsyncLoading();
    state = AsyncData(await _detectFromLocation());
  }

  /// Kullanıcı şehri elle mi sabitledi?
  Future<bool> isManual() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_manualKey);
    return v != null && v.isNotEmpty;
  }
}

/// Aktif şehir (yüklenirken İstanbul) — senkron okunması gereken yerler için.
final activeCityProvider = Provider<TransitCity>((ref) {
  return ref.watch(cityProvider).valueOrNull ?? TransitCities.fallback;
});
