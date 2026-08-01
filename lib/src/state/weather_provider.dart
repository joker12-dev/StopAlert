import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../services/iett_service.dart';
import '../util/platform_check.dart';
import 'journey_provider.dart';

/// Anlık hava durumu (Open-Meteo — ücretsiz, anahtarsız). Konum yoksa null.
class Weather {
  const Weather({required this.tempC, required this.icon, required this.label});

  final int tempC;
  final IconData icon;
  final String label;
}

/// İstanbul anlık trafik yoğunluğu (0-100). Ağ yoksa/başarısızsa null —
/// gösterge o zaman hiç çizilmez. Kaynak: İBB Ulaşım Yönetim Merkezi.
final trafficProvider = FutureProvider<int?>((ref) async {
  if (!isMobileDevice) return null; // test/masaüstü: ağ isteği yok
  return IettService.instance.trafficIndex();
});

final weatherProvider = FutureProvider<Weather?>((ref) async {
  final loc = (await ref.watch(currentLocationProvider.future)).point;
  if (loc == null) return null; // konum yok -> ağ isteği YOK (test güvenli)
  try {
    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=${loc.latitude}&longitude=${loc.longitude}'
      '&current=temperature_2m,weather_code',
    );
    final res = await http.get(uri).timeout(const Duration(seconds: 6));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final cur = j['current'] as Map<String, dynamic>;
    final temp = (cur['temperature_2m'] as num).round();
    final code = (cur['weather_code'] as num).toInt();
    final m = _mapCode(code);
    return Weather(tempC: temp, icon: m.$1, label: m.$2);
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
