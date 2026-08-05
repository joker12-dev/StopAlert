import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Harita işaretlerini GÖRÜNEN ALANA kırpar.
///
/// NEDEN GEREKLİ: `MarkerLayer`, kamera her değiştiğinde (jest boyunca her
/// karede) TÜM işaretlerini yeniden kuruyor — ekran dışındakileri de. 200
/// duraklı bir listede her işaret birkaç widget ettiği için bu, saniyede on
/// binlerce widget demek. Cihaz profilinde ölçüldü: `_MarkerLayerState.build`
/// toplam CPU'nun %93'ünü yiyor, ana iş parçacığı dokunuşa yanıt veremiyor ve
/// uygulama ANR ile çöküyordu.
///
/// Kırpma ekranda görünenle sınırlı olduğu için kullanıcı bir kayıp yaşamaz;
/// yalnızca göremediği işaretler kurulmaz.
abstract final class MarkerCull {
  /// Görünen alanın dışına taşma payı (oran). Kaydırma sırasında kenardan
  /// giren işaretler bir kare geç görünmesin diye biraz geniş tutulur.
  static const _padRatio = 0.25;

  /// [camera]'nın gördüğü alan + pay. Kamera hazır değilse null.
  static LatLngBounds? paddedBounds(MapCamera camera) {
    try {
      final b = camera.visibleBounds;
      final dLat = (b.north - b.south).abs() * _padRatio;
      final dLon = (b.east - b.west).abs() * _padRatio;
      if (!dLat.isFinite || !dLon.isFinite) return null;
      return LatLngBounds(
        LatLng((b.south - dLat).clamp(-90, 90), (b.west - dLon).clamp(-180, 180)),
        LatLng((b.north + dLat).clamp(-90, 90), (b.east + dLon).clamp(-180, 180)),
      );
    } catch (_) {
      return null;
    }
  }

  /// [point] görünür alanda mı (bounds yoksa hepsi görünür sayılır).
  static bool visible(LatLngBounds? bounds, double lat, double lon) {
    if (bounds == null) return true;
    return lat >= bounds.south &&
        lat <= bounds.north &&
        lon >= bounds.west &&
        lon <= bounds.east;
  }
}
