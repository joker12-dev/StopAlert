import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Uygulama dili tercihi.
///
/// Kayıt YOKSA (ilk yükleme) `null` döner → [MaterialApp] sistem dilini kullanır
/// (desteklenen diller arasında eşleşen, yoksa İngilizce). Kullanıcı ayarlardan
/// bir dil seçince cihazda saklanır ve her açılışta o dil uygulanır. "Sistem
/// dili"ne dönmek kaydı siler.
final localeControllerProvider =
    AsyncNotifierProvider<LocaleController, Locale?>(LocaleController.new);

class LocaleController extends AsyncNotifier<Locale?> {
  static const _key = 'app_locale_v1';

  /// Ayarlardaki seçicide gösterilen diller (endonim adlarıyla birlikte).
  static const supported = <({String code, String name})>[
    (code: 'tr', name: 'Türkçe'),
    (code: 'en', name: 'English'),
    (code: 'fr', name: 'Français'),
    (code: 'es', name: 'Español'),
    (code: 'ar', name: 'العربية'),
  ];

  @override
  Future<Locale?> build() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_key);
    if (code == null || code.isEmpty) return null; // sistem dili
    return Locale(code);
  }

  /// [locale] null ise "sistem dili"ne döner (kayıt silinir).
  Future<void> setLocale(Locale? locale) async {
    state = AsyncData(locale);
    final prefs = await SharedPreferences.getInstance();
    if (locale == null) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, locale.languageCode);
    }
  }

  /// Bir dil kodunun endonim adı (seçilmemişse null).
  static String? nameFor(String? code) {
    if (code == null) return null;
    for (final l in supported) {
      if (l.code == code) return l.name;
    }
    return null;
  }
}
