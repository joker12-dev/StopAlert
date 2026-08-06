/// Harita döşeme stilleri — [RouteMap] ve harita ekranları statik olarak okur
/// (Ayarlar ile senkron; [Haptics] / [AppAnim] ile aynı desen).
///
/// Hepsi ÜCRETSİZ ve API ANAHTARI GEREKTİRMEZ:
/// - CartoDB (dark_all / voyager / light_all) — OpenStreetMap tabanlı
/// - Esri World Imagery — uydu görüntüsü
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

enum MapTileStyle {
  /// Renkli, POI ve arazi detaylı — VARSAYILAN (harita sade durmasın).
  canli('Canlı'),

  /// Koyu, minimal (marka rengiyle en uyumlu).
  gece('Gece'),

  /// Uydu görüntüsü (Esri World Imagery).
  uydu('Uydu'),

  /// Açık/sade.
  sade('Sade');

  const MapTileStyle(this.label);
  final String label;

  static MapTileStyle fromName(String name) => MapTileStyle.values.firstWhere(
        (s) => s.name == name,
        orElse: () => MapTileStyle.canli,
      );
}

abstract final class AppMapStyle {
  /// Aktif stil (Ayarlar'dan değişir).
  static MapTileStyle style = MapTileStyle.canli;

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
  static bool get light => style == MapTileStyle.sade;
  static set light(bool v) => style = v ? MapTileStyle.sade : MapTileStyle.gece;

  /// CartoDB varyantı (yalnızca CartoDB stilleri için anlamlı).
  static String get tileVariant => switch (style) {
        MapTileStyle.sade => 'light_all',
        MapTileStyle.canli => 'rastertiles/voyager',
        _ => 'dark_all',
      };

  static const _esri = 'https://server.arcgisonline.com/ArcGIS/rest/services';

  /// Esri tabanlı stiller (raster, {s} ve @2x desteklemez).
  static bool get _esriStyle => style == MapTileStyle.uydu;

  /// Aktif stilin döşeme URL şablonu.
  static String get urlTemplate => switch (style) {
        MapTileStyle.uydu => '$_esri/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        _ => 'https://{s}.basemaps.cartocdn.com/$tileVariant/{z}/{x}/{y}{r}.png',
      };

  /// Esri döşemeleri {s} alt alan adı kullanmaz.
  static List<String> get subdomains =>
      _esriStyle ? const [] : const ['a', 'b', 'c', 'd'];

  /// Retina (@2x) desteği — Esri raster tile'da yok.
  static bool get supportsRetina => !_esriStyle;

  /// Döşeme sağlayıcı atfı (lisans şartı).
  static String get attribution => _esriStyle ? '© Esri' : '© OSM · CARTO';

  /// Uydu zemininde yol/yer adı yok — üstüne ince etiket katmanı bindirilir.
  static bool get needsLabelOverlay => style == MapTileStyle.uydu;

  static const labelOverlayUrl =
      'https://{s}.basemaps.cartocdn.com/dark_only_labels/{z}/{x}/{y}{r}.png';

  static List<String> get labelSubdomains => const ['a', 'b', 'c', 'd'];
}
