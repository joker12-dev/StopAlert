/// Uygulama genelinde SÜREKLİ (repeat) animasyonların açık/kapalı bayrağı.
///
/// Neden: Widget testleri `pumpAndSettle` ile ekranın "durmasını" bekler;
/// sonsuz tekrarlayan bir animasyon (maskot süzülmesi, iskelet parıltısı vb.)
/// asla durmadığı için testi kilitler. Test `setUp`'ında bu bayrak `false`
/// yapılır; böylece bu animasyonlar statik bir kareyle çizilir ve testler
/// serbestçe otursun. Üretimde her zaman `true`.
abstract final class AppAnim {
  static bool enabled = true;
}
