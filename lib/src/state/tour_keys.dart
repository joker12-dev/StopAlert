import 'package:flutter/widgets.dart';

/// Ana sayfa tanıtım turunun ışık tutacağı hedeflerin GlobalKey'leri.
///
/// İlgili widget'lara [KeyedSubtree] ile takılır; tur katmanı bu anahtarlardan
/// hedeflerin ekran üzerindeki dikdörtgenini okuyup spotlight çizer. Tek ana
/// sayfa + tek alt menü olduğu için statik anahtarlar güvenli.
abstract final class TourKeys {
  static final bell = GlobalKey();
  static final search = GlobalKey();
  static final alarm = GlobalKey();
  static final categories = GlobalKey();
  static final nav = GlobalKey();
}
