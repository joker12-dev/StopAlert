import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Konum izni ister ve mevcut konumu döndürür.
///
/// İzin reddedilir ya da servis kapalıysa null döner — harita bu durumda
/// yalnızca hattı gösterir, uygulama çökmez (konum kritik akış değil).
class LocationService {
  /// Konum izni ZATEN verilmişse konumu döndürür; VERİLMEMİŞSE İSTEMEZ.
  ///
  /// Şehir tahmini bunu kullanır: uygulamayı ilk açan kişi karşısında sistem
  /// izin penceresi bulmamalı. İzin, akıştaki "Başlamadan Önce" ekranında
  /// gerekçesiyle birlikte isteniyor.
  Future<LatLng?> currentLocationIfGranted() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        return null;
      }

      // ÖNCE SON BİLİNEN KONUM: anında döner. Şehir tahmini için fazlasıyla
      // yeterli — İstanbul ile Kocaeli arası ~80 km, metrelik hassasiyet
      // gereksiz.
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) return LatLng(last.latitude, last.longitude);

      // Son bilinen yoksa taze konum İSTE ama SÜRE SINIRIYLA. Cihaz sabitken
      // Android konum sağlayıcısını kısıyor ("stationary throttling") ve
      // sınırsız bekleyen çağrı 10-30 sn sürüyor; kullanıcı o boyunca boş
      // ekrana bakıyordu. Süre dolarsa İstanbul'a düşülür, kullanıcı şehri
      // Ayarlar'dan değiştirebilir.
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 4),
        ),
      );
      return LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  Future<LatLng?> currentLocation() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      return LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      return null;
    }
  }

  /// Koordinatı okunabilir bir semt/mahalle adına çevirir (OpenStreetMap
  /// Nominatim — ücretsiz, anahtarsız). Başarısızsa null döner.
  Future<String?> reverseGeocode(LatLng point) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse'
        '?format=jsonv2&lat=${point.latitude}&lon=${point.longitude}'
        '&zoom=16&accept-language=tr',
      );
      final res = await http.get(uri, headers: {
        'User-Agent': 'StopAlert/0.1 (com.originstudios.stopalert)',
      }).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final addr = data['address'] as Map<String, dynamic>?;
      if (addr == null) return null;
      // Öncelik: mahalle > semt > ilçe > şehir.
      final name = addr['neighbourhood'] ??
          addr['suburb'] ??
          addr['quarter'] ??
          addr['city_district'] ??
          addr['town'] ??
          addr['city'] ??
          addr['county'];
      return name as String?;
    } catch (_) {
      return null;
    }
  }
}
