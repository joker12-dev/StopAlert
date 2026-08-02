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

  /// Kısayol yolu — uygulamayı AÇMADAN arka planda alarmı başlatır
  /// (bkz. `home_widget_launcher.dart`).
  static const pathStartAlarm = '/alarm/start';

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

  /// Boş durumdaki tek-dokunuş kısayolları (son yolculuk, favori rota).
  ///
  /// Kısayola basınca uygulama AÇILMAZ; arka planda alarm başlar
  /// (bkz. [homeWidgetBackgroundCallback]). Bu yüzden hattı yeniden kurmaya
  /// yetecek kimlikler de yazılır.
  static Future<void> setShortcuts(List<WidgetShortcut> shortcuts) async {
    if (!isAndroidDevice) return;
    try {
      for (var i = 0; i < 2; i++) {
        final s = i < shortcuts.length ? shortcuts[i] : null;
        await HomeWidget.saveWidgetData<String>('sc${i}_title', s?.title ?? '');
        await HomeWidget.saveWidgetData<String>('sc${i}_sub', s?.subtitle ?? '');
        await HomeWidget.saveWidgetData<String>('sc${i}_code', s?.lineCode ?? '');
        await HomeWidget.saveWidgetData<String>('sc${i}_color', s?.color ?? '');
        await HomeWidget.saveWidgetData<String>('sc${i}_line', s?.lineId ?? '');
        await HomeWidget.saveWidgetData<String>(
            'sc${i}_board', s?.boardingStopId ?? '');
        await HomeWidget.saveWidgetData<String>(
            'sc${i}_target', s?.targetStopId ?? '');
      }
      await HomeWidget.updateWidget(androidName: _provider);
    } catch (_) {}
  }

  /// Bir yolculuk başlarken rotasını hatırla — widget'taki "son yolculuk"
  /// kısayolu bundan üretilir.
  ///
  /// Geçmiş kayıtları ([JourneyRecord]) yalnızca durak ADLARINI tutuyor;
  /// arka planda alarm kurabilmek için KİMLİK gerekiyor, o yüzden ayrı yazılır.
  static Future<void> rememberLastRoute({
    required String lineId,
    required String lineCode,
    required String lineColor,
    required String boardingStopId,
    required String boardingStopName,
    required String targetStopId,
    required String targetStopName,
  }) async {
    if (!isAndroidDevice) return;
    try {
      await HomeWidget.saveWidgetData<String>('last_line', lineId);
      await HomeWidget.saveWidgetData<String>('last_code', lineCode);
      await HomeWidget.saveWidgetData<String>('last_color', lineColor);
      await HomeWidget.saveWidgetData<String>('last_board', boardingStopId);
      await HomeWidget.saveWidgetData<String>(
          'last_board_name', boardingStopName);
      await HomeWidget.saveWidgetData<String>('last_target', targetStopId);
      await HomeWidget.saveWidgetData<String>(
          'last_target_name', targetStopName);
    } catch (_) {}
  }

  /// Hatırlanan son rota — widget kısayolu için (yoksa null).
  static Future<WidgetShortcut?> lastRoute() async {
    if (!isAndroidDevice) return null;
    try {
      final line = await HomeWidget.getWidgetData<String>('last_line');
      final target = await HomeWidget.getWidgetData<String>('last_target');
      if (line == null || line.isEmpty || target == null || target.isEmpty) {
        return null;
      }
      final boardName =
          await HomeWidget.getWidgetData<String>('last_board_name') ?? '';
      final targetName =
          await HomeWidget.getWidgetData<String>('last_target_name') ?? '';
      return WidgetShortcut(
        title: targetName,
        subtitle: boardName.isEmpty ? 'Son yolculuk' : '$boardName → $targetName',
        lineCode: await HomeWidget.getWidgetData<String>('last_code') ?? '',
        color: await HomeWidget.getWidgetData<String>('last_color') ?? '',
        lineId: line,
        boardingStopId:
            await HomeWidget.getWidgetData<String>('last_board') ?? '',
        targetStopId: target,
      );
    } catch (_) {
      return null;
    }
  }

  /// Kısayolun kayıtlı kimlikleri (arka plan isolate'i buradan okur).
  static Future<({String lineId, String boardingStopId, String targetStopId})?>
      shortcutAt(int index) async {
    final line = await HomeWidget.getWidgetData<String>('sc${index}_line');
    final board = await HomeWidget.getWidgetData<String>('sc${index}_board');
    final target = await HomeWidget.getWidgetData<String>('sc${index}_target');
    if (line == null || line.isEmpty || target == null || target.isEmpty) {
      return null;
    }
    return (
      lineId: line,
      boardingStopId: board ?? '',
      targetStopId: target,
    );
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

/// Widget'ın boş durumunda gösterilen tek-dokunuş kısayolu.
class WidgetShortcut {
  const WidgetShortcut({
    required this.title,
    required this.subtitle,
    required this.lineCode,
    required this.color,
    required this.lineId,
    required this.boardingStopId,
    required this.targetStopId,
  });

  /// Üst satır — genelde hedef durak.
  final String title;

  /// Alt satır — "biniş → hedef" ya da "Son yolculuk".
  final String subtitle;
  final String lineCode;

  /// Hat rengi "#RRGGBB" — rozetin dolgusu.
  final String color;

  final String lineId;
  final String boardingStopId;
  final String targetStopId;
}
