/// Harita döşeme stilleri — [RouteMap] ve harita ekranları statik olarak okur
/// (Ayarlar ile senkron; [Haptics] / [AppAnim] ile aynı desen).
///
/// Hepsi ÜCRETSİZ ve API ANAHTARI GEREKTİRMEZ:
/// - CartoDB (dark_all / voyager / light_all) — OpenStreetMap tabanlı
/// - Esri World Imagery — uydu görüntüsü
library;

enum MapTileStyle {
  /// Koyu, minimal (varsayılan; marka rengiyle en uyumlu).
  gece('Gece'),

  /// Renkli, POI ve arazi detaylı — "sade duruyor" diyene canlı alternatif.
  canli('Canlı'),

  /// KOYU ama detaylı (Esri Dark Gray + yol/yer adları). Voyager'ın koyu
  /// sürümü yayınlanmadığı için koyu+detay isteyenlerin karşılığı budur.
  geceDetay('Gece+'),

  /// Uydu görüntüsü (Esri World Imagery).
  uydu('Uydu'),

  /// Açık/sade.
  sade('Sade');

  const MapTileStyle(this.label);
  final String label;

  static MapTileStyle fromName(String name) => MapTileStyle.values.firstWhere(
        (s) => s.name == name,
        orElse: () => MapTileStyle.gece,
      );
}

abstract final class AppMapStyle {
  /// Aktif stil (Ayarlar'dan değişir).
  static MapTileStyle style = MapTileStyle.gece;

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
  static bool get _esriStyle =>
      style == MapTileStyle.uydu || style == MapTileStyle.geceDetay;

  /// Aktif stilin döşeme URL şablonu.
  static String get urlTemplate => switch (style) {
        MapTileStyle.uydu => '$_esri/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        MapTileStyle.geceDetay =>
          '$_esri/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}',
        _ => 'https://{s}.basemaps.cartocdn.com/$tileVariant/{z}/{x}/{y}{r}.png',
      };

  /// Esri döşemeleri {s} alt alan adı kullanmaz.
  static List<String> get subdomains =>
      _esriStyle ? const [] : const ['a', 'b', 'c', 'd'];

  /// Retina (@2x) desteği — Esri raster tile'da yok.
  static bool get supportsRetina => !_esriStyle;

  /// Döşeme sağlayıcı atfı (lisans şartı).
  static String get attribution => _esriStyle ? '© Esri' : '© OSM · CARTO';

  /// Zemin döşemesinde yol/yer adları yoksa üstüne ince etiket katmanı
  /// bindirilir (uydu ve Gece+ için).
  static bool get needsLabelOverlay => _esriStyle;

  /// Etiket katmanı — zeminle aynı sağlayıcıdan (hizalama ve stil tutarlılığı).
  static String get labelOverlayUrl => switch (style) {
        MapTileStyle.geceDetay =>
          '$_esri/Canvas/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}',
        _ => 'https://{s}.basemaps.cartocdn.com/dark_only_labels/'
            '{z}/{x}/{y}{r}.png',
      };

  /// Etiket katmanının {s} kullanıp kullanmadığı (Esri kullanmaz).
  static List<String> get labelSubdomains =>
      style == MapTileStyle.geceDetay ? const [] : const ['a', 'b', 'c', 'd'];
}
