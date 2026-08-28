/// Harita döşeme stilleri — [RouteMap] ve harita ekranları statik olarak okur
/// (Ayarlar ile senkron; [Haptics] / [AppAnim] ile aynı desen).
///
/// Hepsi ÜCRETSİZ ve API ANAHTARI GEREKTİRMEZ:
/// - Standart: OpenStreetMap standart (renkli, modern; VARSAYILAN)
/// - Bisiklet: CyclOSM
/// - Sade: Humanitarian (HOT) — açık/temiz
/// - Gece: Esri Dark Gray Canvas (+ referans etiket katmanı)
/// - Uydu: Esri World Imagery (+ sınır/yer etiketleri)
///
/// NOT: CARTO (basemaps.cartocdn.com) artık anahtar zorunlu kıldığı için
/// bırakıldı. Google Maps'e geçiş faturalandırma + anahtar hazır olunca
/// yapılacak (kullanıcının Google Cloud tarafında).
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

enum MapTileStyle {
  /// OpenStreetMap standart — renkli, detaylı, modern (VARSAYILAN).
  standart('Standart'),

  /// CyclOSM — canlı renkli, sokak/bisiklet detaylı.
  bisiklet('Bisiklet'),

  /// Humanitarian (HOT) — açık, temiz, sade.
  sade('Sade'),

  /// Koyu, minimal (Esri Dark Gray).
  gece('Gece'),

  /// Uydu görüntüsü (Esri World Imagery).
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
  static bool get light => style == MapTileStyle.sade;
  static set light(bool v) => style = v ? MapTileStyle.sade : MapTileStyle.gece;

  static const _esri = 'https://server.arcgisonline.com/ArcGIS/rest/services';

  /// Aktif stilin ZEMİN döşeme URL şablonu. Hepsi ANAHTAR GEREKTİRMEZ:
  /// OSM tabanlılar (standart/bisiklet/sade) + Esri (gece/uydu).
  static String get urlTemplate => switch (style) {
        MapTileStyle.standart =>
          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
        MapTileStyle.bisiklet =>
          'https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png',
        MapTileStyle.sade =>
          'https://{s}.tile.openstreetmap.fr/hot/{z}/{x}/{y}.png',
        MapTileStyle.gece =>
          '$_esri/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}',
        MapTileStyle.uydu =>
          '$_esri/World_Imagery/MapServer/tile/{z}/{y}/{x}',
      };

  /// {s} alt alan adları — yalnızca ilgili OSM sunucularında.
  static List<String> get subdomains => switch (style) {
        MapTileStyle.bisiklet => const ['a', 'b', 'c'],
        MapTileStyle.sade => const ['a', 'b'],
        _ => const [],
      };

  /// Retina (@2x) — bu sağlayıcıların hiçbirinde güvenli değil.
  static bool get supportsRetina => false;

  /// Döşeme sağlayıcı atfı (lisans şartı).
  static String get attribution => switch (style) {
        MapTileStyle.gece || MapTileStyle.uydu => '© Esri',
        _ => '© OpenStreetMap',
      };

  /// Yalnızca Esri gri/uydu zeminlerinde etiketler AYRI referans katmanında;
  /// OSM tabanlı zeminler (standart/bisiklet/sade) etiketleri zaten içerir.
  static bool get needsLabelOverlay =>
      style == MapTileStyle.gece || style == MapTileStyle.uydu;

  /// Aktif stilin etiket (referans) katmanı — zemine göre değişir.
  static String get labelOverlayUrl => switch (style) {
        MapTileStyle.gece =>
          '$_esri/Canvas/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}',
        MapTileStyle.uydu =>
          '$_esri/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}',
        _ => '',
      };

  static List<String> get labelSubdomains => const [];
}
