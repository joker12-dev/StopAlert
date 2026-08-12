import 'package:flutter/material.dart';

/// Alt kenar boşlukları — alt menü ve sistem navigasyon çubuğu payı.
///
/// Alt menü (BottomNavShell) 80 px + sistem çubuğu kadar yer kaplar ve
/// `extendBody: true` ile içeriğin ÜSTÜNDE durur. Kaydırılabilir içeriğin son
/// öğesi menünün altında kalmasın diye liste alt boşluğu buradan alınır.
abstract final class AppInsets {
  /// Alt menünün görünür yüksekliği (sistem çubuğu hariç).
  static const navBarHeight = 80.0;

  /// Sekme ekranlarında (Ana Sayfa, Rotalar, Favoriler, Profil) liste altı.
  ///
  /// Menü `extendBody: true` ile içeriğin ÜSTÜNDE durduğu için son öğe menünün
  /// altında kalıyordu. 12 ve 32 px paylar hâlâ dar geldi; 56 px ile son kart
  /// menüden açıkça ayrılır.
  static double listBottom(BuildContext context) =>
      navBarHeight + 56 + MediaQuery.viewPaddingOf(context).bottom;

  /// Alt menüsü OLMAYAN tam sayfa ekranlarda (push edilmiş) liste altı.
  static double pageBottom(BuildContext context) =>
      40 + MediaQuery.viewPaddingOf(context).bottom;
}
