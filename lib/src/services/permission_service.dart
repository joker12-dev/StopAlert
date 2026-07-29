import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../util/platform_check.dart';

/// İzinlerin toplu durumu.
class PermissionStatusReport {
  const PermissionStatusReport({
    required this.locationWhenInUse,
    required this.locationAlways,
    required this.notifications,
    required this.fullScreenIntent,
    required this.batteryOptimizationExempt,
    required this.overlay,
  });

  final bool locationWhenInUse;
  final bool locationAlways;
  final bool notifications;
  final bool fullScreenIntent;
  final bool batteryOptimizationExempt;

  /// "Diğer uygulamaların üzerinde göster" — OEM'lerde (Xiaomi/Oppo vb.)
  /// tam ekran alarmın arka plandan açılabilmesinin güvencesi (önerilen).
  final bool overlay;

  /// Arka plan takibinin çalışması için zorunlu olanlar.
  bool get criticalGranted =>
      locationAlways && notifications && fullScreenIntent;
}

/// Android sürümüne duyarlı izin akışı (PLAN.md: güvenilirlik ön kontrolü).
///
/// Akış (Android 11+ kuralı): önce "uygulamayı kullanırken" izni istenir;
/// ardından "Her zaman izin ver" istendiğinde sistem kullanıcıyı uygulama
/// ayarlarına götürür. Android 10'da tek diyalogda, Android 9 ve altında
/// arka plan izni kavramı olmadığından fine location yeterlidir —
/// permission_handler bu eşlemeyi kendi içinde yapar.
class PermissionService {
  static const _androidPermissions =
      MethodChannel('stopalert/android_permissions');

  /// Mevcut durumu okur (hiçbir istek göndermez). iOS'ta da konum+bildirim
  /// gerçek durumu okunur; tam ekran/pil/overlay Android'e özeldir (iOS'ta
  /// "geçerli" sayılır — iOS'ta karşılığı yok).
  Future<PermissionStatusReport> check() async {
    if (!isMobileDevice) {
      // Web/masaüstü/test: kapı uygulanmaz.
      return const PermissionStatusReport(
        locationWhenInUse: true,
        locationAlways: true,
        notifications: true,
        fullScreenIntent: true,
        batteryOptimizationExempt: true,
        overlay: true,
      );
    }
    return PermissionStatusReport(
      locationWhenInUse: await Permission.locationWhenInUse.isGranted,
      locationAlways: await Permission.locationAlways.isGranted,
      notifications: await Permission.notification.isGranted,
      fullScreenIntent: isAndroidDevice ? await _canUseFullScreenIntent() : true,
      batteryOptimizationExempt: isAndroidDevice
          ? await Permission.ignoreBatteryOptimizations.isGranted
          : true,
      overlay:
          isAndroidDevice ? await Permission.systemAlertWindow.isGranted : true,
    );
  }

  /// Bildirim izni (Android 13+ / iOS UNUserNotificationCenter).
  Future<bool> requestNotifications() async {
    if (!isMobileDevice) return true;
    return (await Permission.notification.request()).isGranted;
  }

  /// Android 14+ tam ekran alarm izni. Kapalıysa uygulamanın ilgili ayarı açılır.
  Future<bool> requestFullScreenIntent() async {
    if (!isAndroidDevice) return true;
    if (await _canUseFullScreenIntent()) return true;
    try {
      await _androidPermissions.invokeMethod<bool>(
        'openFullScreenIntentSettings',
      );
    } catch (_) {
      await openSettings();
    }
    return _canUseFullScreenIntent();
  }

  /// Adım 1: uygulamayı kullanırken konum izni (Android + iOS).
  Future<bool> requestWhenInUse() async {
    if (!isMobileDevice) return true;
    return (await Permission.locationWhenInUse.request()).isGranted;
  }

  /// Adım 2: "Her zaman izin ver" (Android 11+ / iOS Always). Sistem ayar
  /// sayfası açılabilir; dönüşte [check] ile yeniden doğrulanır.
  Future<bool> requestAlways() async {
    if (!isMobileDevice) return true;
    // Önce when-in-use şart (Android 11+ arka planı direkt istemeyi yasaklar).
    if (!await Permission.locationWhenInUse.isGranted) {
      final ok = await requestWhenInUse();
      if (!ok) return false;
    }
    return (await Permission.locationAlways.request()).isGranted;
  }

  /// Pil optimizasyonu muafiyeti (OEM uygulama katillerine karşı önerilir).
  Future<bool> requestBatteryExemption() async {
    if (!isAndroidDevice) return true;
    return (await Permission.ignoreBatteryOptimizations.request()).isGranted;
  }

  /// "Diğer uygulamaların üzerinde göster" izni — sistem ayar sayfası açılır.
  Future<bool> requestOverlay() async {
    if (!isAndroidDevice) return true;
    return (await Permission.systemAlertWindow.request()).isGranted;
  }

  /// Kullanıcı "bir daha sorma" dediyse tek çıkış: uygulama ayarları.
  Future<void> openSettings() => openAppSettings();

  /// Alarm ses kanalının yüzde düzeyi (0-100; bilinmiyorsa -1).
  ///
  /// Güvenilirlik ön kontrolü: alarm USAGE_ALARM ile çalar; bu kanal kısıksa
  /// kullanıcı yolculuk başlarken uyarılır (PLAN.md ses taraması).
  Future<int> alarmVolumePercent() async {
    if (!isAndroidDevice) return 100;
    try {
      return await _androidPermissions.invokeMethod<int>(
            'getAlarmVolumePercent',
          ) ??
          -1;
    } catch (_) {
      return -1;
    }
  }

  Future<bool> _canUseFullScreenIntent() async {
    if (!isAndroidDevice) return true;
    try {
      return await _androidPermissions.invokeMethod<bool>(
            'canUseFullScreenIntent',
          ) ??
          true;
    } catch (_) {
      // Kanal yoksa (test/masaüstü/erken init) alarmı bloklama.
      return true;
    }
  }
}
