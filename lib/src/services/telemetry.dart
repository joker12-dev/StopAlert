import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import '../util/platform_check.dart';

/// Çökme raporlama (Crashlytics) + olay analitiği (Analytics) sarmalayıcı.
///
/// Amaç (PLAN.md): sahada "alarm çalmadı" gibi kritik durumları ölçmek.
/// Alarm arka plan İZOLATINDA çalar ama Firebase orada başlatılmaz; bu yüzden
/// olaylar ANA izolattaki gözlemlenebilir noktalardan loglanır ('alarm_set' vs
/// 'alarm_shown' hunisi alarmın gerçekten çalıp çalmadığını gösterir).
///
/// Tüm çağrılar mobil-dışı platformlarda ve hata halinde SESSİZCE yutulur.
abstract final class Telemetry {
  static bool _ready = false;

  /// Crashlytics genel hata yakalayıcılarını kurar (main'de, Firebase sonrası).
  static Future<void> init() async {
    if (!isMobileDevice) return;
    try {
      // Flutter framework hataları -> Crashlytics.
      final priorOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        priorOnError?.call(details);
        FirebaseCrashlytics.instance.recordFlutterFatalError(details);
      };
      // Framework dışı (async) hatalar.
      PlatformDispatcher.instance.onError = (error, stack) {
        FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
        return true;
      };
      // Debug'da toplama kapalı; sürümde açık.
      await FirebaseCrashlytics.instance
          .setCrashlyticsCollectionEnabled(!kDebugMode);
      _ready = true;
    } catch (_) {
      // Firebase yok/başlatılamadı: telemetri sessizce devre dışı.
    }
  }

  /// Bir analitik olayı logla (ör. 'alarm_set', 'alarm_shown').
  static void log(String event, [Map<String, Object>? params]) {
    if (!isMobileDevice) return;
    try {
      FirebaseAnalytics.instance.logEvent(name: event, parameters: params);
    } catch (_) {}
  }

  /// Yakalanan bir hatayı (ölümcül olmayan) Crashlytics'e bildir.
  static void recordError(Object error, StackTrace? stack, {String? reason}) {
    if (!isMobileDevice || !_ready) return;
    try {
      FirebaseCrashlytics.instance.recordError(error, stack, reason: reason);
    } catch (_) {}
  }
}
