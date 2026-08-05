import 'package:latlong2/latlong.dart';

/// Harita noktalarının SONLU olduğunu güvence altına alan yardımcılar.
///
/// NEDEN VAR: flutter_map, `MarkerLayer` içinde noktaları izdüşürürken
/// sonsuz/NaN koordinat görürse `RangeError: All markers must have finite
/// points` fırlatıyor. Bu hata LAYOUT içinde atıldığı için her karede
/// tekrarlanıyor; uygulama %196 CPU'ya çıkıp saniyede on binlerce nesne
/// ayırıyor, bellek baskısı sistemi başka uygulamaları öldürmeye zorluyor ve
/// ana iş parçacığı kilitlenince ANR ile çöküyor (cihaz logunda kayıtlı).
///
/// NaN nereden geliyor: ekran koordinatından enlem/boylama çeviren hesaplar
/// (turuncu sonda noktası, kamera ötelemesi) çok parmaklı jest sırasında
/// kameranın geçici durumunda tanımsız değer üretebiliyor. `try/catch` bunu
/// yakalamaz — istisna atılmaz, sessizce NaN döner.
extension LatLngFinite on LatLng {
  /// Nokta haritada çizilebilir mi (sonlu ve dünya sınırları içinde)?
  bool get isUsable =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude.abs() <= 90 &&
      longitude.abs() <= 180;
}

/// Sonlu değilse null döner — çağıran güvenle atlayabilir.
LatLng? safeLatLng(num lat, num lon) {
  final p = LatLng(lat.toDouble(), lon.toDouble());
  return p.isUsable ? p : null;
}

/// Listeden çizilemez noktaları ayıklar (polyline/marker kaynakları için).
List<LatLng> onlyUsable(Iterable<LatLng> points) =>
    [for (final p in points) if (p.isUsable) p];
