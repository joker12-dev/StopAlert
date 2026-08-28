/// Harita döşeme stilleri — [RouteMap] ve harita ekranları statik olarak okur
/// (Ayarlar ile senkron; [Haptics] / [AppAnim] ile aynı desen).
///
/// KATMANLAR (hepsi Mapbox — tek sağlayıcı, tutarlı görünüm):
/// - Standart: Mapbox Streets (renkli, POI etiketli; VARSAYILAN)
/// - Açık: Mapbox Light (sade, açık)
/// - Koyu: Mapbox Dark
/// - Uydu: Mapbox Satellite Streets
///
/// NOT: flutter_map RASTER (düz) döşeme kullanır. Mapbox'ın yeni "Standard/
/// Faded/Monochrome" stilleri 3D/vektördür ve raster (Static Tiles) API'sinde
/// çalışmaz (400 döner) — yalnızca KLASİK stiller raster olur. Faded/Monochrome
/// istenirse Mapbox Studio'da KLASİK tabanlı özel stil yayımlanıp ID'si buraya
/// eklenmeli.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

enum MapTileStyle {
  /// Mapbox Streets — renkli, POI etiketli (VARSAYILAN).
  standart('Standart'),

  /// Mapbox Light — sade, açık.
  acik('Açık'),

  /// Mapbox Dark — koyu.
  koyu('Koyu'),

  /// Mapbox Satellite Streets — uydu + etiket.
  uydu('Uydu');

  const MapTileStyle(this.label);
  final String label;

  static MapTileStyle fromName(String name) => MapTileStyle.values.firstWhere(
        (s) => s.name == name,
        orElse: () => MapTileStyle.standart,
      );
}

abstract final class AppMapStyle {
  /// Aktif stil (Ayarlar'dan değişir).
  static MapTileStyle style = MapTileStyle.standart;

  /// Görünen alanın ÖTESİNDE kaç halka karo tutulsun.
  ///
  /// flutter_map varsayılanı 2; hızlı kaydırmada ekran dışı karolar birikip
  /// belleği şişiriyordu (cihazda "Out of Memory" ile çökme kaydedildi).
  /// 1 halka, kaydırırken boş kare görmeye yetecek kadar önden yükler ama
  /// bellekte tuttuğu karo sayısını belirgin azaltır.
  static const keepBuffer = 1;

  /// Kaydırma yönünde ÖN YÜKLEME halkası. 0 = yalnızca görünen alan.
  static const panBuffer = 0;

  /// En fazla uzaklaşma sınırı.
  ///
  /// Eskiden 3'tü — kıta ölçeği. Uygulama şehir içi bir alarm aracı; tüm
  /// dünyayı görmenin bir faydası yok ama ciddi bir zararı var: tam
  /// uzaklaşınca hattın/şehrin BÜTÜN durakları görünen alana giriyor,
  /// ekran dışını eleyen kırpma işlevsiz kalıyor ve harita her kamera
  /// hareketinde binlerce işareti yeniden kuruyor (cihaz profilinde
  /// MarkerLayer.build toplam CPU'nun %93'ü, sonuç ANR).
  ///
  /// 9: yaklaşık 300 km genişlik — İstanbul-Kocaeli arası şehirlerarası bir
  /// hat bile tek ekrana sığar.
  static const minZoom = 9.0;

  /// Yakındaki duraklar haritası daha yerel: 10 ≈ 150 km.
  static const minZoomLocal = 10.0;

  static const maxZoom = 18.0;

  /// Yakınlaşma jestlerinin YUMUŞATILMASI.
  ///
  /// ÖNEMLİ SINIR: parmakla sıkıştırma (pinch) flutter_map'te birebir
  /// fizikseldir — `zoom = başlangıç + log2(ölçek)` — ve paket bunun için bir
  /// hız çarpanı sunmuyor. Yani "pinch'i yavaşlat" ayarı YOK; buradakiler
  /// gerçekten ayarlanabilen öteki yakınlaşma yolları.
  ///
  /// [flags] çağırana bırakılır: takip haritası salt-okunur modda hiçbir
  /// etkileşime izin vermiyor.
  static InteractionOptions interaction({required int flags}) =>
      InteractionOptions(
        flags: flags,
        // Çift dokun + yukarı/aşağı sürükle: varsayılanın YARISI. İstenen
        // kademeye isabet etmek kolaylaşıyor.
        doubleTapDragZoomChangeCalculator: (offset, camera) =>
            (1 / 720) * camera.zoom * offset,
        // 200 ms'de bir kademe atlamak "zıplama" gibi duruyordu.
        doubleTapZoomDuration: const Duration(milliseconds: 350),
        doubleTapZoomCurve: Curves.easeOutCubic,
        // Fare tekerleği (masaüstü / emülatör) de yarı hız.
        scrollWheelVelocity: 0.0025,
        // Savurma daha çabuk dursun: uzun kayışlar boyunca harita sürekli
        // yeniden çiziliyor.
        flingAnimationDampingRatio: 8.0,
      );

  /// Eski API — true = açık tema. Ayarlardaki 'light'/'dark' ile uyum için.
  static bool get light => style == MapTileStyle.acik;
  static set light(bool v) => style = v ? MapTileStyle.acik : MapTileStyle.koyu;

  /// Mapbox genel erişim token'ı (pk.…).
  ///
  /// Mapbox token'ları uygulamada açık taşınmak üzere tasarlıdır (pk = public);
  /// güvenlik için Mapbox panelinden kullanım limiti/URL kısıtı eklenebilir.
  /// Boşsa haritalar OSM standart'a düşer (kırık kalmaz).
  static const mapboxToken =
      'pk.eyJ1IjoiY2MyYW5uIiwiYSI6ImNtdGNyaXJ2bDBpb2wyd3I2bXF3MWZnbWUifQ.ejRQoOPwOEKB5QwoljeJxg';

  static bool get hasMapbox => mapboxToken.isNotEmpty;

  /// Stilin Mapbox klasik stil kimliği (raster Static Tiles API ile uyumlu).
  static String _mapboxId(MapTileStyle s) => switch (s) {
        MapTileStyle.standart => 'streets-v12',
        MapTileStyle.acik => 'light-v11',
        MapTileStyle.koyu => 'dark-v11',
        MapTileStyle.uydu => 'satellite-streets-v12',
      };

  /// Aktif stilin ZEMİN döşeme URL şablonu. Token varsa Mapbox; yoksa güvenlik
  /// için OSM standart (kırık harita gösterme).
  ///
  /// `{r}` → yüksek yoğunluklu ekranda flutter_map bunu `@2x` yapar; Mapbox
  /// 1024 px döşeme döndürür → NETLİK belirgin artar (bitmap büyütme azalır).
  static String get urlTemplate => hasMapbox
      ? 'https://api.mapbox.com/styles/v1/mapbox/${_mapboxId(style)}/tiles/512/{z}/{x}/{y}{r}?access_token=$mapboxToken'
      : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Mapbox {s} alt alan adı kullanmaz.
  static List<String> get subdomains => const [];

  /// Mapbox raster döşemeleri 512 px; 256'lık şemaya oturması için
  /// tileDimension 512 + zoomOffset -1. Token yoksa (OSM) 256/0.
  static int get tileDimension => hasMapbox ? 512 : 256;
  static double get zoomOffset => hasMapbox ? -1 : 0;

  /// Retina (@2x): Mapbox destekler → yüksek yoğunluklu ekranda keskin.
  static bool get supportsRetina => hasMapbox;

  /// Döşeme sağlayıcı atfı (lisans şartı).
  static String get attribution =>
      hasMapbox ? '© Mapbox © OpenStreetMap' : '© OpenStreetMap';

  /// Mapbox stilleri etiketleri zaten içerir — ayrı katman gerekmez.
  static bool get needsLabelOverlay => false;
  static String get labelOverlayUrl => '';
  static List<String> get labelSubdomains => const [];
}
