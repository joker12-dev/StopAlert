import 'package:flutter/widgets.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'ad_service.dart';
import '../util/platform_check.dart';

/// Uygulama-açılış (App Open) reklamı — kullanıcı uygulamaya GERİ döndüğünde
/// bir kez tam ekran gösterilir.
///
/// NEDEN BU BİÇİM: kullanıcı tam-ekran reklamdan rahatsız olmasın diye akış
/// İÇİNDE geçiş reklamı göstermiyoruz; bunun yerine yalnızca uygulama arka
/// plandan öne gelince (ör. başka uygulamaya bakıp dönünce) gösteriyoruz. Bu,
/// AdMob'un App Open için önerdiği ve en az rahatsız eden yerdir.
///
/// KURALLAR:
///  - SOĞUK AÇILIŞTA GÖSTERİLMEZ: ilk açılış zaten rıza/izin/veri akışı; oraya
///    reklam koymak hem AdMob politikasına aykırı hem itici.
///  - Reklam gösterilirken uygulama öne gelirse (reklamın kendi tam ekranı)
///    tekrar tetiklenmez ([_showing] muhafızı).
///  - Bir bekleme süresi var: arka plana çok kısa geçişlerde (bildirim çekme,
///    izin penceresi) reklam patlamasın.
class AppOpenAdManager with WidgetsBindingObserver {
  AppOpenAdManager._();
  static final AppOpenAdManager instance = AppOpenAdManager._();

  AppOpenAd? _ad;
  bool _loading = false;
  bool _showing = false;

  /// İlk öne-geliş ATLANIR: onResume soğuk açılışta da geliyor.
  bool _coldStart = true;

  /// Reklam bu süreden kısa arka-plan geçişlerinde gösterilmez.
  static const _minBackground = Duration(seconds: 4);
  DateTime? _backgroundedAt;

  bool _started = false;

  /// Yaşam döngüsünü dinlemeye başla ve ilk reklamı önden yükle.
  void start() {
    if (!isMobileDevice || _started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  void _load() {
    if (_loading || _ad != null) return;
    _loading = true;
    AppOpenAd.load(
      adUnitId: AdConfig.appOpenUnitId,
      request: const AdRequest(),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (ad) {
          _ad = ad;
          _loading = false;
        },
        onAdFailedToLoad: (_) {
          _ad = null;
          _loading = false;
        },
      ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Reklamın kendi tam ekranı da "paused" üretir; onu arka plan sayma.
      if (!_showing) _backgroundedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      _onResume();
    }
  }

  void _onResume() {
    // İLK ÖNE-GELİŞ = soğuk açılış: atla, ama bir sonrakine hazır ol.
    if (_coldStart) {
      _coldStart = false;
      _load();
      return;
    }
    if (_showing) return;
    // Çok kısa arka-plan geçişinde gösterme (izin penceresi, bildirim vb.).
    final since = _backgroundedAt;
    if (since != null &&
        DateTime.now().difference(since) < _minBackground) {
      return;
    }
    _show();
  }

  void _show() {
    final ad = _ad;
    if (ad == null) {
      _load(); // hazır değildi: bir sonraki dönüş için yükle
      return;
    }
    _showing = true;
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        _showing = false;
        ad.dispose();
        _ad = null;
        _load(); // sonraki dönüş için yeniden yükle
      },
      onAdFailedToShowFullScreenContent: (ad, _) {
        _showing = false;
        ad.dispose();
        _ad = null;
        _load();
      },
    );
    ad.show();
  }

  void dispose() {
    if (!_started) return;
    WidgetsBinding.instance.removeObserver(this);
    _ad?.dispose();
    _ad = null;
    _started = false;
  }
}
