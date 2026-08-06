import 'package:in_app_review/in_app_review.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/platform_check.dart';
import 'telemetry.dart';

/// "Uygulamayı puanla" isteminin NE ZAMAN çıkacağını yöneten kural.
///
/// Kural bilinçli olarak cimri: istem, kullanıcı uygulamadan bir FAYDA
/// gördükten sonra — ilk yolculuğunu tamamlayıp ana sayfaya döndüğünde —
/// bir kez çıkar. Açılışta ya da yolculuk ortasında puan istemek, alarmı
/// bekleyen kullanıcının önünü kesmek olurdu.
///
/// Kullanıcı "Daha sonra" derse istem susar ve ancak birkaç yolculuk sonra
/// tekrar denenir; "İstemiyorum" derse bir daha hiç çıkmaz.
abstract final class AppReviewService {
  static const _completedKey = 'review_completed_journeys_v1';
  static const _neverKey = 'review_never_v1';
  static const _pendingKey = 'review_pending_v1';
  static const _lastAskedAtCountKey = 'review_last_asked_count_v1';

  /// "Daha sonra" dendikten sonra yeniden sormak için gereken yolculuk sayısı.
  static const _retryAfterJourneys = 5;

  /// Bir yolculuk tamamlandı (varış ekranı açıldı). Sayaç artar ve istem
  /// BEKLEMEYE alınır — asıl gösterim ana sayfaya dönüşte olur.
  static Future<void> onJourneyCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    final count = (prefs.getInt(_completedKey) ?? 0) + 1;
    await prefs.setInt(_completedKey, count);
    if (prefs.getBool(_neverKey) ?? false) return;

    final lastAsked = prefs.getInt(_lastAskedAtCountKey) ?? -1;
    final firstTime = lastAsked < 0 && count >= 1;
    final retry = lastAsked >= 0 && count - lastAsked >= _retryAfterJourneys;
    if (firstTime || retry) await prefs.setBool(_pendingKey, true);
  }

  /// Ana sayfa açıldığında: bekleyen bir istem var mı?
  static Future<bool> consumePending() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_neverKey) ?? false) return false;
    if (!(prefs.getBool(_pendingKey) ?? false)) return false;
    // Tek seferlik: bayrak burada düşer, diyalog kapansa da tekrar açılmaz.
    await prefs.setBool(_pendingKey, false);
    await prefs.setInt(
        _lastAskedAtCountKey, prefs.getInt(_completedKey) ?? 0);
    return true;
  }

  /// Kullanıcı "İstemiyorum" dedi — bir daha sorulmaz.
  static Future<void> never() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_neverKey, true);
    await prefs.setBool(_pendingKey, false);
    Telemetry.log('review_declined');
  }

  /// Mağazanın YERLİ puanlama akışını aç.
  ///
  /// `requestReview` sistemin kendi penceresidir; Google/Apple bunu sıklık
  /// kotasına tabi tutar ve pencere hiç görünmeyebilir — bu normaldir ve
  /// hata değildir. Bu yüzden dönüş değeri yok: kullanıcıya "açılmadı"
  /// diye bir hata göstermek yanlış olurdu.
  static Future<void> request() async {
    if (!isMobileDevice) return;
    try {
      final review = InAppReview.instance;
      if (await review.isAvailable()) {
        await review.requestReview();
        Telemetry.log('review_requested');
      }
    } catch (_) {
      // Mağaza yoksa (yan yükleme, emülatör) sessizce geç.
    }
  }
}
