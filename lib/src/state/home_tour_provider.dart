import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ana sayfa tanıtım turu GÖSTERİLDİ mi?
///
/// Kullanıcı uygulamayı ilk açıp ana sayfaya geldiğinde tur bir kez oynar;
/// bittiğinde ya da "Atla"ya basınca bir daha çıkmaz. Ayarlardan tekrar
/// başlatmak istenirse [HomeTourSeen.reset] çağrılabilir.
final homeTourSeenProvider =
    AsyncNotifierProvider<HomeTourSeen, bool>(HomeTourSeen.new);

class HomeTourSeen extends AsyncNotifier<bool> {
  static const _key = 'home_tour_done_v1';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> markDone() async {
    state = const AsyncData(true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }

  Future<void> reset() async {
    state = const AsyncData(false);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, false);
  }
}
