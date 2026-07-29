/// Harita döşeme stili — [RouteMap] statik olarak okur (Ayarlar ile senkron
/// tutulur; [Haptics] / [AppAnim] ile aynı desen). CartoDB varyantı döner.
abstract final class AppMapStyle {
  /// true = açık (Sade / light_all), false = koyu (Gece / dark_all).
  static bool light = false;

  static String get tileVariant => light ? 'light_all' : 'dark_all';
}
