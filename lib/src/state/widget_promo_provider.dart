import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ana sayfadaki "ana ekrana widget ekle" tanıtım kartı KAPATILDI mı?
///
/// Bir kez kapatılınca (ya da kullanıcı ekleme akışını başlatınca) kart geri
/// gelmez — her açılışta aynı tanıtımı görmek sinir bozucu olurdu. Ayarlardaki
/// "widget ekle" satırı her zaman durur; bu yalnızca ana sayfadaki tek
/// seferlik hatırlatma içindir.
final widgetPromoDismissedProvider =
    AsyncNotifierProvider<WidgetPromoDismissed, bool>(
        WidgetPromoDismissed.new);

class WidgetPromoDismissed extends AsyncNotifier<bool> {
  static const _key = 'widget_promo_dismissed_v1';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  Future<void> dismiss() async {
    state = const AsyncData(true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }
}
