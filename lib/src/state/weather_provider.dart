import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'journey_provider.dart';

/// Anlık hava durumu (Open-Meteo — ücretsiz, anahtarsız). Konum yoksa null.
class Weather {
  const Weather({
    required this.tempC,
    required this.icon,
    required this.label,
    this.sunrise,
    this.sunset,
  });

  final int tempC;
  final IconData icon;
  final String label;

  /// Bugünün gün doğumu/batımı (cihazın yerel saatinde).
  ///
  /// Aynı istekte geliyor — ana sayfa başlık görselinin gündüz mü gece mi
  /// olacağını buradan belirliyoruz (bkz. [isNightProvider]).
  final DateTime? sunrise;
  final DateTime? sunset;
}

final weatherProvider = FutureProvider<Weather?>((ref) async {
  final loc = (await ref.watch(currentLocationProvider.future)).point;
  if (loc == null) return null; // konum yok -> ağ isteği YOK (test güvenli)
  try {
    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=${loc.latitude}&longitude=${loc.longitude}'
      '&current=temperature_2m,weather_code'
      // Güneş saatleri AYNI istekte: ek çağrı maliyeti yok.
      '&daily=sunrise,sunset&timezone=auto&forecast_days=1',
    );
    final res = await http.get(uri).timeout(const Duration(seconds: 6));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final cur = j['current'] as Map<String, dynamic>;
    final temp = (cur['temperature_2m'] as num).round();
    final code = (cur['weather_code'] as num).toInt();
    final m = _mapCode(code);
    final daily = j['daily'] as Map<String, dynamic>?;
    return Weather(
      tempC: temp,
      icon: m.$1,
      label: m.$2,
      sunrise: _firstTime(daily?['sunrise']),
      sunset: _firstTime(daily?['sunset']),
    );
  } catch (_) {
    return null;
  }
});

/// WMO hava kodu -> (Material ikon, kısa etiket). Emoji yerine ikon
/// (tasarım sistemi: arayüzde emoji kullanılmaz).
(IconData, String) _mapCode(int c) {
  if (c == 0) return (Icons.wb_sunny_rounded, 'Açık');
  if (c <= 3) return (Icons.wb_cloudy_rounded, 'Parçalı');
  if (c == 45 || c == 48) return (Icons.cloud_rounded, 'Sisli');
  if (c >= 51 && c <= 67) return (Icons.water_drop_rounded, 'Yağmurlu');
  if (c >= 71 && c <= 77) return (Icons.ac_unit_rounded, 'Karlı');
  if (c >= 80 && c <= 82) return (Icons.grain_rounded, 'Sağanak');
  if (c >= 95) return (Icons.bolt_rounded, 'Fırtına');
  return (Icons.cloud_rounded, '');
}

/// `daily.sunrise` / `daily.sunset` dizisinin ilk değeri ("2026-08-09T06:07").
/// `timezone=auto` sayesinde YEREL saat geliyor, dönüşüm gerekmiyor.
DateTime? _firstTime(Object? v) {
  if (v is! List || v.isEmpty) return null;
  return DateTime.tryParse('${v.first}');
}

/// Şu an gece mi?
///
/// Canlı gün doğumu/batımı varsa ondan; yoksa SABİT kurala düşer (konum ya da
/// ağ yokken de bir cevap vermek gerekiyor). Sabit sınırlar İstanbul'un yıl
/// ortalamasına yakın seçildi; yaz akşamları bir saat kadar erken "gece"
/// diyebilir, bu yalnızca arka plan fotoğrafını etkiler.
final isNightProvider = Provider<bool>((ref) {
  final w = ref.watch(weatherProvider).valueOrNull;
  final now = DateTime.now();
  final sunrise = w?.sunrise;
  final sunset = w?.sunset;
  if (sunrise != null && sunset != null) {
    return now.isBefore(sunrise) || now.isAfter(sunset);
  }
  return now.hour < 7 || now.hour >= 20;
});
