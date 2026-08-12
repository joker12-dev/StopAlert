import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Kullanım koşulları + gizlilik/KVKK onayı verildi mi.
///
/// SÜRÜMLÜ TUTULUYOR: metin esaslı biçimde değişirse (yeni bir veri işleme
/// amacı eklenirse) anahtar numarası artırılır ve onay yeniden alınır. Eski
/// bir metne verilmiş rızayı yeni bir amaç için kullanmak geçerli bir rıza
/// sayılmaz.
final consentProvider =
    AsyncNotifierProvider<ConsentNotifier, bool>(ConsentNotifier.new);

class ConsentNotifier extends AsyncNotifier<bool> {
  static const _prefsKey = 'consent_accepted_v1';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefsKey) ?? false;
  }

  Future<void> accept() async {
    state = const AsyncData(true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKey, true);
  }
}
