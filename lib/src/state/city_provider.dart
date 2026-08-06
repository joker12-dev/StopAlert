import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/transit_city.dart';
import '../services/bus_data_service.dart';
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
  ///
  /// Tahmin edilen şehrin PAKETİ İNDİRİLMEMİŞSE o şehre geçilmez: uygulama
  /// bomboş görünür (hat yok, durak yok). Böyle bir durumda yüklü paketler
  /// arasından konuma en yakın olan seçilir.
  Future<TransitCity> _detectFromLocation() async {
    if (!isMobileDevice) return TransitCities.fallback;
    try {
      final pos = await LocationService().currentLocationIfGranted();
      if (pos == null) return TransitCities.fallback;
      final guess = TransitCities.forLocation(pos.latitude, pos.longitude);
      if (await BusDataService.instance.hasLocal(guess)) return guess;
      return await _nearestInstalled(pos.latitude, pos.longitude) ?? guess;
    } catch (_) {
      return TransitCities.fallback;
    }
  }

  /// Paketi İNDİRİLMİŞ şehirler arasından konuma en yakın olanı.
  Future<TransitCity?> _nearestInstalled(double lat, double lon) async {
    TransitCity? best;
    var bestD = double.infinity;
    for (final c in TransitCities.all) {
      if (!await BusDataService.instance.hasLocal(c)) continue;
      final d = c.roughDistance(lat, lon);
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return best;
  }

  /// Paketi yeni inen şehri etkinleştir — ama "elle seçim" DAMGASI VURMADAN.
  ///
  /// [select]'ten farkı bu damga. Paket indirmek "artık hep bu şehirdeyim"
  /// demek değil; damga vurulunca konuma göre otomatik şehir belirleme kalıcı
  /// olarak susuyordu ve İstanbul paketini bir kez indiren Kocaeli'ndeki
  /// kullanıcı İstanbul'da takılı kalıyordu. Kalıcı sabitleme yalnızca
  /// Ayarlar'daki şehir seçiminden ([select]) gelir.
  Future<void> setActive(TransitCity city) async {
    state = AsyncData(city);
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
