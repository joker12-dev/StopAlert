/// Uygulamanın veri paketi olan şehirler.
///
/// Her şehrin toplu taşıma verisi AYRI bir paket olarak indirilir ve aynı anda
/// yalnızca BİRİ açıktır. Hepsini tek havuzda toplamak cazip görünse de
/// arama kalitesini bozuyor: İstanbul'da 13.000, Kocaeli'de 8.400 durak var ve
/// "İZMİT" yazınca İstanbul'daki "İZMİT CADDESİ" ile karışıyor. Kullanıcı da
/// pratikte tek şehirde yolculuk ediyor.
library;

/// Bir şehir paketi.
class TransitCity {
  const TransitCity({
    required this.id,
    required this.name,
    required this.attribution,
    required this.minLat,
    required this.maxLat,
    required this.minLon,
    required this.maxLon,
    this.hasLiveBus = false,
    this.hasTraffic = false,
  });

  /// Dosya/kayıt anahtarı (`bus_istanbul.sqlite`, manifest yolu…).
  final String id;

  /// Kullanıcıya gösterilen ad.
  final String name;

  /// Veri sağlayıcı ataması — lisans gereği EKRANDA görünmek zorunda.
  final String attribution;

  // Konumdan şehir tahmini için kaba sınırlayıcı kutu.
  final double minLat;
  final double maxLat;
  final double minLon;
  final double maxLon;

  /// Canlı otobüs konumu var mı (İETT açık servis veriyor, Kocaeli vermiyor).
  final bool hasLiveBus;

  /// Trafik yoğunluğu göstergesi var mı.
  final bool hasTraffic;

  bool contains(double lat, double lon) =>
      lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon;

  /// Kutunun merkezine uzaklık (derece cinsinden kaba ölçü) — hangi şehre
  /// daha yakın olduğunu seçmek için.
  double roughDistance(double lat, double lon) {
    final dy = lat - (minLat + maxLat) / 2;
    final dx = lon - (minLon + maxLon) / 2;
    return dy * dy + dx * dx;
  }

  @override
  bool operator ==(Object other) => other is TransitCity && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

abstract final class TransitCities {
  static const istanbul = TransitCity(
    id: 'istanbul',
    name: 'İstanbul',
    attribution: 'Veri: İETT · İBB Açık Veri Portalı',
    minLat: 40.75,
    maxLat: 41.65,
    minLon: 27.90,
    maxLon: 29.95,
    hasLiveBus: true,
    hasTraffic: true,
  );

  static const kocaeli = TransitCity(
    id: 'kocaeli',
    name: 'Kocaeli',
    // CC BY lisansı atfı ZORUNLU kılıyor.
    attribution: 'Veri: Kocaeli Büyükşehir Belediyesi Açık Veri Portalı (CC BY)',
    minLat: 40.42,
    maxLat: 41.25,
    minLon: 29.10,
    maxLon: 30.40,
  );

  static const all = [istanbul, kocaeli];

  static const fallback = istanbul;

  static TransitCity byId(String? id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return fallback;
  }

  /// Konuma en uygun şehir. Hiçbir kutuya girmiyorsa en yakını seçilir —
  /// kullanıcı şehirlerarası yolda olabilir; boş ekran göstermektense en
  /// yakın şehirle başlamak yeğdir (üstteki çipten değiştirebilir).
  static TransitCity forLocation(double lat, double lon) {
    for (final c in all) {
      if (c.contains(lat, lon)) return c;
    }
    var best = fallback;
    var bestD = double.infinity;
    for (final c in all) {
      final d = c.roughDistance(lat, lon);
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return best;
  }
}
