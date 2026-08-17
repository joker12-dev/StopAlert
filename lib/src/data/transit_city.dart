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
    required this.centerLat,
    required this.centerLon,
    this.hasLiveBus = false,
    this.hasTraffic = false,
    this.hasAnnouncements = false,
    this.hasTimetable = false,
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

  /// Haritaların KONUM YOKKEN açılacağı yer.
  ///
  /// Kutunun geometrik merkezi işe yaramıyor: İstanbul kutusunun merkezi
  /// (41,20 / 28,93) Karadeniz kıyısına düşüyor. Bunlar şehrin gerçek
  /// merkezleri. Sabit bir İstanbul koordinatı gömmek ise Kocaeli'ndeki
  /// kullanıcıya haritayı Beyoğlu'nda açıyordu.
  final double centerLat;
  final double centerLon;

  /// Canlı otobüs konumu var mı.
  final bool hasLiveBus;

  /// Trafik yoğunluğu göstergesi var mı.
  final bool hasTraffic;

  /// Hat duyurusu beslemesi var mı (İETT sefer iptali/duyuru servisi).
  final bool hasAnnouncements;

  /// Planlanan sefer saati (kalkış takvimi) servisi var mı.
  ///
  /// İETT "PlanlananSeferSaati" servisini açık veriyor. Kocaeli'nin GTFS
  /// paketinde `stop_times` yok ve portalda eşdeğer bir uç bulunmuyor —
  /// olmayan veriyi düğme yapmak ölü dokunuş olurdu.
  final bool hasTimetable;

  bool contains(double lat, double lon) =>
      lat >= minLat && lat <= maxLat && lon >= minLon && lon <= maxLon;

  /// Kutunun merkezine kaba uzaklığın karesi — hangi şehre daha yakın
  /// olduğunu seçmek için. Boylam derecesi 41. paralelde enlem derecesinin
  /// ~0,75'i kadar mesafe ettiğinden ölçeklenir; yoksa doğu-batı farkları
  /// olduğundan büyük görünür.
  double roughDistance(double lat, double lon) {
    const lonScale = 0.75;
    final dy = lat - (minLat + maxLat) / 2;
    final dx = (lon - (minLon + maxLon) / 2) * lonScale;
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
    centerLat: 41.0082, // Sultanahmet
    centerLon: 28.9784,
    hasLiveBus: true,
    hasTraffic: true,
    hasAnnouncements: true,
    hasTimetable: true,
  );

  static const kocaeli = TransitCity(
    id: 'kocaeli',
    name: 'Kocaeli',
    // CC BY lisansı atfı ZORUNLU kılıyor.
    attribution:
        'Veri: Kocaeli Büyükşehir Belediyesi Açık Veri Portalı (CC BY)',
    minLat: 40.42,
    // Kuzey sınır 41,10: daha yukarısı İstanbul'un Şile kıyısı. Şile (41,175)
    // ile Kandıra (41,07) aynı boylam kuşağında olduğu için kutu buradan
    // kesilmezse Şile Kocaeli sanılıyordu.
    maxLat: 41.10,
    // Batı sınır Dilovası; Gebze (29,43) dahil kalır.
    minLon: 29.30,
    maxLon: 30.40,
    centerLat: 40.7654, // İzmit
    centerLon: 29.9408,
    // Akıllı Şehir Kocaeli anlık yoğunluk servisi veriyor.
    hasLiveBus: true,
    hasTraffic: true,
    // Kalkış saatleri PAKETE GÖMÜLÜ (belediyenin hat sayfasından derlenir).
    hasTimetable: true,
  );

  static const all = [istanbul, kocaeli];

  static const fallback = istanbul;

  static TransitCity byId(String? id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return fallback;
  }

  /// Konuma en uygun şehir.
  ///
  /// Kutular ÇAKIŞIYOR: İstanbul ili doğuda 29,95'e kadar uzanıyor ve İzmit
  /// (29,94) o kutunun içinde kalıyor. Bu yüzden "kutusuna giren ilk şehir"
  /// yanlış: kutuya girenler arasından MERKEZİ EN YAKIN olan seçilir.
  ///
  /// Hiçbir kutuya girmiyorsa yine en yakın şehir döner — kullanıcı
  /// şehirlerarası yolda olabilir; boş ekran göstermektense en yakın şehirle
  /// başlamak yeğdir (Ayarlar'dan değiştirebilir).
  static TransitCity forLocation(double lat, double lon) {
    TransitCity? inside;
    var insideD = double.infinity;
    var best = fallback;
    var bestD = double.infinity;
    for (final c in all) {
      final d = c.roughDistance(lat, lon);
      if (c.contains(lat, lon) && d < insideD) {
        insideD = d;
        inside = c;
      }
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return inside ?? best;
  }
}
