import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/platform_check.dart';

/// AdMob reklam birimi kimlikleri.
///
/// VARSAYILAN olarak Google'ın resmi TEST kimlikleri kullanılır (kendi
/// hesabını riske atmadan geliştirme). Yayına çıkmadan önce AdMob konsolundan
/// aldığın GERÇEK "geçiş (interstitial)" reklam birimi kimliklerini aşağıdaki
/// [_realInterstitialAndroid] / [_realInterstitialIos] alanlarına yapıştır.
///
/// Not: Uygulama kimliği (App ID, `~` içerir) reklam birimi kimliğinden (`/`
/// içerir) FARKLIDIR ve native tarafta tutulur:
///   - Android: AndroidManifest.xml -> com.google.android.gms.ads.APPLICATION_ID
///   - iOS: Info.plist -> GADApplicationIdentifier
abstract final class AdConfig {
  // Google resmi TEST geçiş reklamı birimleri (silme, yedek olarak kalsın).
  static const _testInterstitialAndroid =
      'ca-app-pub-3940256099942544/1033173712';
  static const _testInterstitialIos =
      'ca-app-pub-3940256099942544/4411468910';

  // ---- GERÇEK geçiş (interstitial) kimlikleri (AdMob konsolu, StopAlert) ----
  static const _realInterstitialAndroid =
      'ca-app-pub-6579751877708140/5616295898';
  static const _realInterstitialIos =
      'ca-app-pub-6579751877708140/3931945063';

  // Google resmi TEST banner birimleri.
  static const _testBannerAndroid = 'ca-app-pub-3940256099942544/6300978111';
  static const _testBannerIos = 'ca-app-pub-3940256099942544/2934735716';

  // ---- GERÇEK banner kimlikleri (AdMob konsolu, StopAlert) ----
  static const _realBannerAndroid = 'ca-app-pub-6579751877708140/4690492961';
  static const _realBannerIos = 'ca-app-pub-6579751877708140/9930231414';

  /// Aktif platformun geçiş reklamı birimi kimliği.
  static String get interstitialUnitId {
    if (isIosDevice) {
      return _realInterstitialIos.isNotEmpty
          ? _realInterstitialIos
          : _testInterstitialIos;
    }
    return _realInterstitialAndroid.isNotEmpty
        ? _realInterstitialAndroid
        : _testInterstitialAndroid;
  }

  // Google resmi TEST yerel (native advanced) birimleri.
  static const _testNativeAndroid = 'ca-app-pub-3940256099942544/2247696110';
  static const _testNativeIos = 'ca-app-pub-3940256099942544/3986624511';

  // ---- GERÇEK yerel (native advanced) kimlikleri (AdMob konsolu) ----
  //
  // BOŞ BIRAKILIRSA test reklamı gösterilir — gerçek kimlik yokken canlı
  // reklam istemek hesap askıya alınmasına yol açar.
  static const _realNativeAndroid = 'ca-app-pub-6579751877708140/3567479950';
  static const _realNativeIos = 'ca-app-pub-6579751877708140/8059001105';

  /// Aktif platformun yerel reklam birimi kimliği (gerçek yoksa TEST).
  static String get nativeUnitId {
    if (isIosDevice) {
      return _realNativeIos.isNotEmpty ? _realNativeIos : _testNativeIos;
    }
    return _realNativeAndroid.isNotEmpty
        ? _realNativeAndroid
        : _testNativeAndroid;
  }

  /// Yerel reklam GERÇEK kimlikle mi çalışıyor (arayüz test rozeti gösterir).
  static bool get nativeIsTest =>
      isIosDevice ? _realNativeIos.isEmpty : _realNativeAndroid.isEmpty;

  /// Aktif platformun banner reklam birimi kimliği (gerçek yoksa TEST).
  static String get bannerUnitId {
    if (isIosDevice) {
      return _realBannerIos.isNotEmpty ? _realBannerIos : _testBannerIos;
    }
    return _realBannerAndroid.isNotEmpty
        ? _realBannerAndroid
        : _testBannerAndroid;
  }

  // Google resmi TEST uygulama-açılış birimleri.
  static const _testAppOpenAndroid = 'ca-app-pub-3940256099942544/9257395921';
  static const _testAppOpenIos = 'ca-app-pub-3940256099942544/5575463023';

  // ---- GERÇEK uygulama-açılış kimlikleri (AdMob konsolu, StopAlert) ----
  static const _realAppOpenAndroid = 'ca-app-pub-6579751877708140/3008395538';
  static const _realAppOpenIos = 'ca-app-pub-6579751877708140/1005048723';

  /// Aktif platformun uygulama-açılış reklam birimi kimliği (gerçek yoksa TEST).
  static String get appOpenUnitId {
    if (isIosDevice) {
      return _realAppOpenIos.isNotEmpty ? _realAppOpenIos : _testAppOpenIos;
    }
    return _realAppOpenAndroid.isNotEmpty
        ? _realAppOpenAndroid
        : _testAppOpenAndroid;
  }

  /// GELİŞTİRME CİHAZLARI — buraya eklenen cihazlar AdMob'a "test" olarak
  /// bildirilir: bizim denemelerimiz gerçek istek/gösterim istatistiklerini
  /// (eşleşme oranı, eBGBM) KİRLETMEZ ve geçersiz trafik riski oluşmaz.
  ///
  /// Kimliği bulmak için: uygulamayı cihazda aç, logcat'te şu satırı ara —
  ///   "Use RequestConfiguration.Builder().setTestDeviceIds(Arrays.asList(\"ABC…\"))"
  /// oradaki kimliği aşağıya ekle.
  static const testDeviceIds = <String>[
    // 'BURAYA_CIHAZ_KIMLIGI',
  ];
}

/// Geçiş (interstitial) reklamını YALNIZCA İndin (varış) ekranında,
/// alarm akışına asla dokunmadan yönetir.
///
/// - Yolculuk başlarken [preloadInterstitial] ile arka planda önden yüklenir.
/// - İndin'de [maybeShowInterstitial]: hazır ve günlük sınır aşılmadıysa
///   gösterir; değilse SESSİZCE atlar (asla bekletmez, asla hata göstermez).
/// - Sıklık sınırı: günde en fazla [_maxPerDay] gösterim (cihazda sayaç).
class AdService {
  AdService._();
  static final AdService instance = AdService._();

  static const _maxPerDay = 2;

  bool _initialized = false;
  bool _loading = false;
  InterstitialAd? _ad;

  /// MobileAds SDK'sını bir kez başlatır (mobil dışı platformda no-op).
  Future<void> init() async {
    if (!isMobileDevice || _initialized) return;
    _initialized = true;
    try {
      // Geliştirme cihazlarını işaretle (varsa) — istatistikler temiz kalsın.
      if (AdConfig.testDeviceIds.isNotEmpty) {
        await MobileAds.instance.updateRequestConfiguration(
          RequestConfiguration(testDeviceIds: AdConfig.testDeviceIds),
        );
      }
      await MobileAds.instance.initialize();
    } catch (_) {
      // SDK başlatılamadı: reklamlar sessizce devre dışı kalır.
    }
  }

  /// Geçiş reklamını arka planda yükler (yolculuk başında çağrılır).
  void preloadInterstitial() {
    if (!isMobileDevice || _ad != null || _loading) return;
    _loading = true;
    InterstitialAd.load(
      adUnitId: AdConfig.interstitialUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
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

  /// İndin ekranında çağrılır. Reklam hazır ve günlük sınır aşılmadıysa
  /// gösterir ve kapanınca döner; aksi halde hemen (sessizce) döner.
  Future<void> maybeShowInterstitial() async {
    if (!isMobileDevice) return;
    final ad = _ad;
    if (ad == null) return; // yüklenmedi -> sessiz atla
    if (!await _underDailyCap()) return; // günlük sınır -> atla, reklamı sakla

    _ad = null;
    final done = Completer<void>();
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (a) {
        a.dispose();
        if (!done.isCompleted) done.complete();
        preloadInterstitial(); // sonraki yolculuk için önden yükle
      },
      onAdFailedToShowFullScreenContent: (a, _) {
        a.dispose();
        if (!done.isCompleted) done.complete();
      },
    );
    await _incrementDailyCount();
    ad.show();
    return done.future;
  }

  Future<bool> _underDailyCap() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getInt(_todayKey()) ?? 0) < _maxPerDay;
  }

  Future<void> _incrementDailyCount() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _todayKey();
    await prefs.setInt(key, (prefs.getInt(key) ?? 0) + 1);
  }

  String _todayKey() {
    final n = DateTime.now();
    final m = n.month.toString().padLeft(2, '0');
    final d = n.day.toString().padLeft(2, '0');
    return 'ad_interstitial_${n.year}$m$d';
  }
}
