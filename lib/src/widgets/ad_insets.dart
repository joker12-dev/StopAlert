import 'package:flutter/material.dart';

/// Alt menüye yapışık banner reklamın yüksekliğini alt ağaca taşır.
///
/// NEDEN GEREKLİ: banner artık her sayfada ayrı ayrı değil, alt menünün
/// hemen üstünde TEK ve SABİT duruyor. `extendBody: true` olduğu için de
/// sayfaların içeriğinin üstünü örtüyor. Liste alt boşlukları bu yüksekliği
/// bilmezse her sekmenin son öğesi reklamın altında kalır.
///
/// Reklam yüklenince yükseklik değişiyor ve InheritedWidget sayesinde
/// boşluğu okuyan ekranlar kendiliğinden yeniden çiziliyor — global bir
/// değişken bunu yapamazdı.
class AdInsets extends InheritedWidget {
  const AdInsets({
    super.key,
    required this.bannerHeight,
    required super.child,
  });

  /// Yüklü banner yüksekliği (yoksa 0).
  final double bannerHeight;

  /// Ağaçta yoksa 0 döner: alt menüsüz tam sayfa ekranlarda reklam da yok.
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AdInsets>()?.bannerHeight ?? 0;

  @override
  bool updateShouldNotify(AdInsets old) => old.bannerHeight != bannerHeight;
}
