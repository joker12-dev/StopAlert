import 'package:home_widget/home_widget.dart';

import '../util/platform_check.dart';

/// Ana ekran widget'ının beslendiği yer (Android App Widget).
///
/// Widget iki durumda çalışır:
///   • Aktif alarm YOK  → "Aktif alarm yok" + "Alarm kur" düğmesi
///   • Alarm kurulu     → kalan durak halkası, kalan mesafe, şu anki ve
///     sonraki durak
///
/// Veri `SharedPreferences` üzerinden Kotlin tarafına geçer; widget uygulama
/// kapalıyken de son yazılan değeri gösterir. Güncelleme çağrıları hem ana
/// isolate'ten hem ön plan servisinin arka plan isolate'inden gelebilir
/// (bkz. [TrackingTaskHandler] `_publish`), böylece uygulama tamamen kapalıyken
/// bile widget canlı kalır.
abstract final class HomeWidgetService {
  /// Kotlin tarafındaki sağlayıcı sınıfı — [AppWidgetProvider] alt sınıfı.
  static const _provider = 'StopAlertWidgetProvider';

  /// Widget'a dokununca açılan derin bağlantılar.
  static const schemeHost = 'stopalert';
  static const pathNewAlarm = '/alarm/new';
  static const pathTracking = '/tracking';

  /// Üst üste bu kadar hata alınırsa vazgeçilir (widget eklenmemiş olabilir);
  /// yeni yolculukta sayaç sıfırlanır.
  static int _failures = 0;
  static const _maxFailures = 3;

  /// Widget'ı en fazla bu sıklıkta yeniden çiz. GPS saniyede bir gelebiliyor;
  /// halkayı her seferinde bitmap olarak üretmek gereksiz pil yakar. İçerik
  /// (durak/durum) değişince beklemeden güncellenir.
  static const _minInterval = Duration(seconds: 5);
  static DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  static String _lastSignature = '';

  /// Takip sürerken çağrılır (her konum güncellemesinde).
  ///
  /// [stopsRemaining] / [stopsTotal] halkanın dolum oranını verir; [state]
  /// [JourneyState] adıdır (active/approaching/signalLost/arrived/waiting).
  static Future<void> update({
    required String lineCode,
    required String lineColor,
    required String targetStop,
    required String currentStop,
    required String nextStop,
    required int stopsRemaining,
    required int stopsTotal,
    required double distanceMeters,
    required int etaMinutes,
    required String state,
  }) async {
    if (!isAndroidDevice || _failures >= _maxFailures) return;
    // İçerik aynıysa ve aralık dolmadıysa çizme.
    final signature = '$state|$stopsRemaining|$currentStop|$nextStop';
    final now = DateTime.now();
    if (signature == _lastSignature &&
        now.difference(_lastPush) < _minInterval) {
      return;
    }
    _lastSignature = signature;
    _lastPush = now;
    try {
      await Future.wait([
        HomeWidget.saveWidgetData<bool>('active', true),
        HomeWidget.saveWidgetData<String>('line', lineCode),
        HomeWidget.saveWidgetData<String>('color', lineColor),
        HomeWidget.saveWidgetData<String>('target', targetStop),
        HomeWidget.saveWidgetData<String>('current', currentStop),
        HomeWidget.saveWidgetData<String>('next', nextStop),
        HomeWidget.saveWidgetData<int>('stops_remaining', stopsRemaining),
        HomeWidget.saveWidgetData<int>('stops_total', stopsTotal),
        HomeWidget.saveWidgetData<String>('distance', formatDistance(distanceMeters)),
        HomeWidget.saveWidgetData<int>('eta', etaMinutes),
        HomeWidget.saveWidgetData<String>('state', state),
      ]);
      await HomeWidget.updateWidget(androidName: _provider);
      _failures = 0;
    } catch (_) {
      // Widget yoksa/eklenmemişse sessizce geç — takip asla etkilenmemeli.
      _failures++;
    }
  }

  /// Yolculuk bitti/iptal edildi: widget boş duruma döner.
  static Future<void> clear() async {
    if (!isAndroidDevice) return;
    _failures = 0; // yeni yolculukta tekrar denensin
    _lastSignature = '';
    try {
      await HomeWidget.saveWidgetData<bool>('active', false);
      await HomeWidget.updateWidget(androidName: _provider);
    } catch (_) {}
  }

  /// Uygulama widget'a dokunularak açıldıysa hedef bağlantı (yoksa null).
  static Future<Uri?> initialLaunchUri() async {
    if (!isAndroidDevice) return null;
    try {
      return await HomeWidget.initiallyLaunchedFromHomeWidget();
    } catch (_) {
      return null;
    }
  }

  /// Uygulama açıkken widget'a dokunulduğunda gelen bağlantılar.
  static Stream<Uri?> get clicks => HomeWidget.widgetClicked;

  /// "350 m" / "1,2 km" — widget dar olduğu için kısa biçim.
  static String formatDistance(double meters) {
    if (meters.isNaN || meters < 0) return '—';
    if (meters < 1000) return '${meters.round()} m';
    final km = meters / 1000;
    final s = km < 10 ? km.toStringAsFixed(1) : km.round().toString();
    return '${s.replaceAll('.', ',')} km';
  }
}
