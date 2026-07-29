import 'package:live_activities/live_activities.dart';

import '../util/platform_check.dart';

/// iOS Live Activity (kilit ekranı + Dynamic Island) yönetimi.
///
/// Yolculuk boyunca "kalan durak · sonraki durak · ~ETA" bilgisini canlı
/// gösterir (Trendyol/Uber Eats teslimat kartı gibi). Yalnızca iOS 16.1+; diğer
/// platformlarda ve hata halinde SESSİZCE no-op olur (Android'de karşılığı ön
/// plan servisinin kalıcı bildirimidir).
///
/// SwiftUI widget'ı bu verileri App Group üzerinden okur (bkz. ios/ kurulum
/// notu: LIVE_ACTIVITY_SETUP.md).
class LiveActivityService {
  LiveActivityService._();
  static final LiveActivityService instance = LiveActivityService._();

  final LiveActivities _la = LiveActivities();
  bool _inited = false;
  bool _active = false;

  /// App Group kimliği — hem Runner hem Widget Extension bu grubu paylaşmalı.
  static const appGroupId = 'group.com.originstudios.stopalert.liveactivity';

  /// Sabit etkinlik kimliği (createOrUpdate ile başlat+güncelle aynı id'de).
  static const _activityId = 'stopalert_journey';

  Future<void> _ensureInit() async {
    if (_inited) return;
    _inited = true;
    await _la.init(appGroupId: appGroupId);
  }

  Map<String, dynamic> _data({
    required String lineCode,
    required String lineColor,
    required String targetStop,
    required int stopsRemaining,
    required String nextStop,
    required int etaMinutes,
    required String state,
  }) =>
      {
        'lineCode': lineCode,
        'lineColor': lineColor, // "#RRGGBB"
        'targetStop': targetStop,
        'stopsRemaining': stopsRemaining,
        'nextStop': nextStop,
        'etaMinutes': etaMinutes,
        'state': state, // active | approaching | signalLost | arrived | waiting
      };

  /// Canlı etkinliği başlat ya da güncelle (her durum değişiminde çağrılır).
  Future<void> sync({
    required String lineCode,
    required String lineColor,
    required String targetStop,
    required int stopsRemaining,
    required String nextStop,
    required int etaMinutes,
    required String state,
  }) async {
    if (!isIosDevice) return;
    try {
      await _ensureInit();
      await _la.createOrUpdateActivity(
        _activityId,
        _data(
          lineCode: lineCode,
          lineColor: lineColor,
          targetStop: targetStop,
          stopsRemaining: stopsRemaining,
          nextStop: nextStop,
          etaMinutes: etaMinutes,
          state: state,
        ),
      );
      _active = true;
    } catch (_) {}
  }

  bool get isActive => _active;

  /// Canlı etkinliği bitir (varış/iptal/ekrandan çıkış).
  Future<void> end() async {
    if (!isIosDevice || !_active) return;
    _active = false;
    try {
      await _la.endActivity(_activityId);
    } catch (_) {}
  }
}
