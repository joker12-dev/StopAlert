import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../data/favorite_route.dart';
import '../data/journey_payload.dart';
import '../data/journey_record.dart';
import '../data/models.dart';
import '../engine/geo.dart' as geo;
import '../engine/journey_engine.dart';
import '../services/alarm_notifications.dart';
import '../services/live_activity_service.dart';
import '../services/location_service.dart';
import '../services/segment_learning_store.dart';
import '../services/telemetry.dart';
import '../services/tracking_service.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/platform_check.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mascot.dart';
import '../widgets/progress_ring.dart';
import '../widgets/route_map.dart';
import '../widgets/skeleton.dart';
import '../widgets/slide_to_action.dart';
import 'alarm_ringing_screen.dart';
import 'arrival_screen.dart';
import 'permission_gate_screen.dart';

/// Hareket testi için "Simüle et" butonunu gösterir.
///
/// Web'de uygulama içi motoru, Android'de GERÇEK arka plan servisini sürer
/// (bildirim + alarm + tam ekran intent dahil uçtan uca test). Mağaza
/// sürümünde kapatmak için false yap.
const bool kShowSimulateButton = true;

/// Canlı Takip — konum motoruyla beslenen canlı yolculuk ekranı.
///
/// ANDROID: takip, konum tipli ön plan SERVİSİNDE koşar — uygulamadan
/// çıkılsa, ekran kilitlense, son uygulamalardan atılsa bile sürer; bu ekran
/// yalnızca servisin yayınladığı durumu gösterir ve uygulama yeniden
/// açıldığında kaldığı yerden devam eder.
///
/// WEB/DİĞER: takip uygulama içinde koşar (gerçek GPS + emniyet kemeri),
/// istenirse simülasyonla test edilir.
class LiveTrackingScreen extends ConsumerStatefulWidget {
  const LiveTrackingScreen({
    super.key,
    required this.payload,
    this.restored = false,
  });

  /// Yolculuğun tamamı (hat + biniş/iniş + alarm mesafesi). null ise
  /// hat verisi olmayan bir giriş denenmiştir; boş durum gösterilir.
  final JourneyPayload? payload;

  /// true: uygulama yeniden açıldı, servis zaten koşuyor — yeni servis başlatma.
  final bool restored;

  @override
  ConsumerState<LiveTrackingScreen> createState() => _LiveTrackingScreenState();
}

class _LiveTrackingScreenState extends ConsumerState<LiveTrackingScreen> {
  JourneyEngine? _engine; // web/uygulama içi mod + rota görüntüleme
  List<Stop> _route = const [];
  List<LatLng> _points = const [];
  List<geo.LatLng> _geoPoints = const [];

  // Uygulama içi (web) mod
  StreamSubscription<Position>? _gpsSub;
  Timer? _beltTimer;
  Timer? _simTimer;
  double _simProgress = 0;
  bool _simulating = false;

  final DateTime _start = DateTime.now();
  JourneyStatus? _status;
  LatLng? _pos;
  bool _alarmed = false;
  bool _permissionDenied = false;
  bool _serviceMode = false;

  /// Varış İndin sayfasına yalnızca bir kez geçilir.
  bool _arrivedHandled = false;

  /// "Yaklaşma" alarmı durduruldu ama daha varılmadı: takip sürüyor.
  bool _alarmAcknowledged = false;

  /// Ertele penceresi (null = ertelenmiyor) + saniyelik UI sayacı.
  DateTime? _snoozeUntil;
  Timer? _snoozeTimer;
  Timer? _uiTicker;

  int get _elapsedSec => DateTime.now().difference(_start).inSeconds;

  TransitLine? get _line => widget.payload?.line;
  String get _targetStopName => widget.payload?.targetStopName ?? '';
  String get _lineLabel => _line?.code ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    final payload = widget.payload;
    if (payload == null) return;

    final engine = JourneyEngine(
      line: payload.line,
      boardingStopId: payload.boardingStopId,
      targetStopId: payload.targetStopId,
      alarmDistanceMeters: payload.alarmDistanceMeters,
      alarmStopsThreshold: payload.alarmStopsThreshold,
    );
    setState(() {
      _engine = engine;
      _route = engine.routeStops;
      _points = [for (final s in _route) LatLng(s.lat, s.lon)];
      _geoPoints = [for (final s in _route) geo.LatLng(s.lat, s.lon)];
    });

    if (isAndroidDevice) {
      _serviceMode = true;
      TrackingController.ensureInitialized();
      TrackingController.addListener(_onServiceData);
      if (widget.restored) {
        // Servis zaten koşuyor: son durumu yükle.
        final last = await TrackingController.lastUpdate();
        if (last != null) _applyUpdate(last);
      } else {
        final ok = await TrackingController.start(payload);
        if (!ok && mounted) {
          final retried = await _repairPermissionsAndRetry(payload);
          if (!retried && mounted) {
            setState(() => _permissionDenied = true);
          }
        }
      }
      return;
    }

    // Uygulama içi mod (web): gerçek GPS + emniyet kemeri.
    _beltTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_alarmed && engine.shouldForceAlarm(_elapsedSec)) {
        _alarmed = true;
        _fireAlarmInApp();
      }
    });
    await _startInAppGps();
  }

  // ---- Android servis modu ----

  Future<bool> _repairPermissionsAndRetry(JourneyPayload payload) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PermissionGateScreen(
          onCompleted: () {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ),
      ),
    );
    if (!mounted) return false;
    final ok = await TrackingController.start(payload);
    if (ok && mounted) setState(() => _permissionDenied = false);
    return ok;
  }

  void _onServiceData(Object data) {
    final update = TrackingUpdate.tryDecode(data);
    if (update == null || !mounted) return;
    _applyUpdate(update);
  }

  void _applyUpdate(TrackingUpdate update) {
    setState(() {
      _pos = LatLng(update.lat, update.lon);
      _status = JourneyStatus(
        state: JourneyState.values.asNameMap()[update.state] ??
            JourneyState.active,
        stopsRemaining: update.stopsRemaining,
        distanceToTargetMeters: update.distanceMeters,
        nextStopName: update.nextStopName,
        etaSeconds: update.etaSeconds,
        confidence: update.confidence,
      );
    });
    final s = _status;
    if (s != null) _syncLiveActivity(s);
    if (update.alarmActive && !_alarmed) {
      _alarmed = true;
      _openAlarmScreen();
    }
    // Servis "arrived" bildirdiyse (fiilen durakta) İndin sayfasına geç.
    if (update.state == JourneyState.arrived.name) {
      _maybeArrived();
    }
  }

  // ---- Uygulama içi (web) modu ----

  Future<void> _startInAppGps() async {
    final first = await LocationService().currentLocation();
    if (!mounted) return;
    if (first == null) {
      setState(() => _permissionDenied = true);
    } else {
      _onPosition(first, 20);
    }
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(
      (p) => _onPosition(LatLng(p.latitude, p.longitude), p.accuracy),
      onError: (_) {},
    );
  }

  void _onPosition(LatLng pos, double accuracy) {
    final engine = _engine;
    if (engine == null) return;
    final status = engine.update(GpsSample(
      point: geo.LatLng(pos.latitude, pos.longitude),
      accuracyMeters: accuracy,
      elapsed: Duration(seconds: _elapsedSec),
    ));
    if (!mounted) return;
    setState(() {
      _pos = pos;
      _status = status;
    });
    _syncLiveActivity(status);
    if (!_alarmed && status.state == JourneyState.approaching) {
      _alarmed = true;
      _fireAlarmInApp();
    }
    if (status.state == JourneyState.arrived) {
      _maybeArrived();
    }
  }

  /// iOS Live Activity'i (kilit ekranı kartı) başlat/güncelle. iOS dışında
  /// no-op (Android karşılığı: ön plan servisinin kalıcı bildirimi).
  void _syncLiveActivity(JourneyStatus status) {
    if (!isIosDevice) return;
    final line = _line;
    final color =
        line != null ? lineTypeColor(line.type) : VigilantColors.primary;
    LiveActivityService.instance.sync(
      lineCode: _lineLabel,
      lineColor: _colorHex(color),
      targetStop: _targetStopName,
      stopsRemaining: status.stopsRemaining,
      nextStop: status.nextStopName,
      etaMinutes: (status.etaSeconds / 60).ceil(),
      state: status.state.name,
    );
  }

  String _colorHex(Color c) {
    int ch(double v) => (v * 255).round().clamp(0, 255);
    String h(int v) => v.toRadixString(16).padLeft(2, '0');
    return '#${h(ch(c.r))}${h(ch(c.g))}${h(ch(c.b))}';
  }

  /// Fiilen hedefe varıldıysa İndin sayfasına yalnızca bir kez geç.
  /// (Alarm ekranı açıkken bekler: kullanıcı önce alarmı kapatır.)
  void _maybeArrived() {
    if (_arrivedHandled || _alarmScreenOpen) return;
    _completeJourney();
  }

  /// Yolculuğu başarıyla tamamla: takibi/servisi durdur, İndin sayfasına geç.
  void _completeJourney() {
    if (_arrivedHandled) return;
    _arrivedHandled = true;
    Telemetry.log('journey_arrived');
    LiveActivityService.instance.end();
    _snoozeTimer?.cancel();
    _uiTicker?.cancel();
    // ÖĞRENME: uygulama içi (web/masaüstü) modda ölçülen segment sürelerini
    // burada kaydet; servis modunda arka plan görevi zaten kaydeder.
    if (!_serviceMode) {
      final obs = _engine?.observations() ?? const [];
      if (obs.isNotEmpty) unawaited(SegmentLearningStore.record(obs));
    }
    // Öğrenilen sayı rozetini tazele (Ayarlar → Öğrenme).
    ref.invalidate(learnedSegmentCountProvider);
    _stopTracking();
    if (_serviceMode) unawaited(TrackingController.stop());
    _goToArrival();
  }

  /// Yeraltı (sinyal yok) testi: GPS'i keser, zaman sayacıyla hızlandırılmış
  /// ölü hesap sürer — "sinyal yok" durumu, kalan durak azalışı ve varış
  /// zinciri gerçek yoldan görülür.
  void _toggleUndergroundSimulation() {
    if (_simulating) return;
    if (_serviceMode) {
      TrackingController.sendCommand(TrackingCommands.simulateUnderground);
      setState(() => _simulating = true);
      return;
    }
    final engine = _engine;
    if (engine == null || _points.length < 2) return;
    _simulating = true;
    _gpsSub?.cancel();
    // Binişi bir kez besle (motoru aktive et), sonra sinyalsiz ilerlet.
    _onPosition(_points.first, 8);
    var virtualSec = 0;
    _simTimer = Timer.periodic(const Duration(milliseconds: 600), (timer) {
      virtualSec += 20;
      final status = engine.updateNoSignal(Duration(seconds: virtualSec));
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _status = status);
      if (!_alarmed && status.state == JourneyState.approaching) {
        _alarmed = true;
        _fireAlarmInApp();
      }
      if (status.state == JourneyState.arrived) {
        timer.cancel();
        _maybeArrived();
      }
    });
    setState(() {});
  }

  void _toggleSimulation() {
    if (_simulating) return;
    // Android: simülasyonu gerçek arka plan servisi yürütür — bildirim,
    // alarm ve kalıcı durum dahil tüm zincir gerçek yoldan test edilir.
    if (_serviceMode) {
      TrackingController.sendCommand(TrackingCommands.simulate);
      setState(() => _simulating = true);
      return;
    }
    _simulating = true;
    _gpsSub?.cancel();
    _simProgress = 0;
    _simTimer = Timer.periodic(const Duration(milliseconds: 700), (timer) {
      if (_points.length < 2) return;
      final segCount = _points.length - 1;
      _simProgress = (_simProgress + 0.14).clamp(0.0, segCount.toDouble());
      final seg = _simProgress.floor().clamp(0, segCount - 1);
      final frac = _simProgress - seg;
      final a = _points[seg];
      final b = _points[seg + 1];
      _onPosition(
        LatLng(
          a.latitude + (b.latitude - a.latitude) * frac,
          a.longitude + (b.longitude - a.longitude) * frac,
        ),
        8,
      );
    });
    setState(() {});
  }

  // ---- Alarm + varış akışı ----

  Future<void> _fireAlarmInApp() => _openAlarmScreen();

  bool _alarmScreenOpen = false;

  Future<void> _openAlarmScreen() async {
    if (_alarmScreenOpen || !mounted) return;
    _alarmScreenOpen = true;
    // Alarm ekranı fiilen gösterildi — "alarm çalmadı" hunisi için kritik olay.
    Telemetry.log('alarm_shown');
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AlarmRingingScreen(
          stopName: _targetStopName,
          distanceText: _formatDistance(_status?.distanceToTargetMeters),
          snoozeMinutes: widget.payload?.snoozeMinutes ?? 5,
        ),
      ),
    );
    _alarmScreenOpen = false;
    // Bildirim (sesli/insistent) iptalini UI tarafında da garanti et: servis
    // komutu kaybolsa bile alarm sesi susar (idempotent, Android dışında no-op).
    AlarmNotifications.cancelAlarm();
    if (!mounted) return;
    if (result == 'snooze') {
      _snoozeAlarm();
      return;
    }
    // Kaydırarak durdur. Kullanıcı GERÇEKTEN vardıysa İndin'e geç; aksi halde
    // (ör. 500 m kala durdurdu) alarmı sustur ama takibi SÜRDÜR — varışta
    // ekran kendiliğinden İndin sayfasına ilerler.
    if (_status?.state == JourneyState.arrived) {
      _completeJourney();
      return;
    }
    _alarmAcknowledged = true;
    if (_serviceMode) {
      TrackingController.sendCommand(TrackingCommands.dismissAlarm);
    }
    if (mounted) setState(() {}); // durum satırı "durağa yaklaşıyorsun"a döner
  }

  /// Ertele: alarmı sustur, [snoozeMinutes] boyunca tekrar çalma; takip sürer.
  void _snoozeAlarm() {
    final minutes = widget.payload?.snoozeMinutes ?? 5;
    _alarmed = true; // ertele penceresinde yeniden açma
    _snoozeUntil = DateTime.now().add(Duration(minutes: minutes));
    if (_serviceMode) {
      TrackingController.sendCommand(TrackingCommands.snooze);
    }
    _snoozeTimer?.cancel();
    _snoozeTimer = Timer(Duration(minutes: minutes), () {
      _snoozeUntil = null;
      _alarmed = false; // hâlâ yaklaşıyorsa alarm yeniden çalabilir
      _uiTicker?.cancel();
      if (mounted) setState(() {});
    });
    // Kalan ertele süresini saniyelik güncelle (canlı takipteki sayaç).
    _uiTicker?.cancel();
    _uiTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    if (mounted) setState(() {});
  }

  void _stopTracking() {
    _gpsSub?.cancel();
    _simTimer?.cancel();
    _beltTimer?.cancel();
    if (_serviceMode) {
      TrackingController.removeListener(_onServiceData);
    }
  }

  String? _formatDistance(double? meters) {
    if (meters == null) return null;
    return meters >= 1000
        ? '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
        : '${meters.round()} m';
  }

  void _goToArrival() {
    final line = _line;
    final code = line?.code ?? _lineLabel;
    final record = JourneyRecord(
      lineCode: code,
      lineName: line?.name ?? code,
      lineTypeName: (line?.type ?? LineType.bus).name,
      boardingStopName: _route.isNotEmpty ? _route.first.name : '',
      targetStopName: _targetStopName,
      durationSeconds: _elapsedSec,
      stopsTraveled: _route.isNotEmpty ? _route.length - 1 : 0,
      status: 'completed',
    );

    FavoriteRoute? favorite;
    final payload = widget.payload;
    if (line != null && payload != null && _route.length >= 2) {
      favorite = FavoriteRoute(
        lineId: line.id,
        lineCode: code,
        lineName: line.name,
        lineTypeName: line.type.name,
        boardingStopId: payload.boardingStopId,
        boardingStopName: _route.first.name,
        targetStopId: payload.targetStopId,
        targetStopName: _route.last.name,
      );
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ArrivalScreen(record: record, favorite: favorite),
      ),
    );
  }

  /// 0..1 güveni kullanıcı diline çevirir (PLAN.md: güven göstergesi).
  String _confidenceLabel(double c) =>
      c >= 0.7 ? 'yüksek' : (c >= 0.4 ? 'orta' : 'zayıf');

  /// Başlık altındaki tek satırlık durum metni.
  String _statusLine(JourneyStatus? status) {
    if (_permissionDenied && !_simulating) {
      return 'Konum izni yok — yalnızca zaman tabanlı yedek alarm çalışır.';
    }
    if (status == null) return '$_targetStopName için takip hazırlanıyor…';
    if (status.state == JourneyState.waiting) {
      final boarding = _route.isNotEmpty ? _route.first.name : 'biniş durağı';
      return '$boarding durağına gidiliyor — takip binişte başlayacak';
    }
    if (status.state == JourneyState.signalLost) {
      return 'Sinyal yok — zaman + ivmeölçerle tahmini takip · '
          'güven: ${_confidenceLabel(status.confidence)}';
    }
    if (_alarmAcknowledged) {
      return 'Alarm durduruldu — $_targetStopName durağına yaklaşıyorsun.';
    }
    return '${status.nextStopName} yönünde ilerleniyor · '
        'GPS güveni: ${_confidenceLabel(status.confidence)}';
  }

  /// Ertele sürüyorsa "mm:ss" kalan; aksi halde null.
  String? get _snoozeCountdown {
    final until = _snoozeUntil;
    if (until == null) return null;
    final remaining = until.difference(DateTime.now());
    if (remaining.isNegative) return null;
    final m = remaining.inMinutes;
    final s = remaining.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _cancelJourney() async {
    Telemetry.log('journey_cancelled');
    LiveActivityService.instance.end();
    _stopTracking();
    if (_serviceMode) await TrackingController.stop();
    // Yarıda kesilen yolculuk da geçmişe yazılır (status: cancelled).
    final line = _line;
    if (line != null && _route.isNotEmpty && _status != null) {
      unawaited(ref.read(journeyRepositoryProvider).save(JourneyRecord(
            lineCode: line.code,
            lineName: line.name,
            lineTypeName: line.type.name,
            boardingStopName: _route.first.name,
            targetStopName: _targetStopName,
            durationSeconds: _elapsedSec,
            stopsTraveled: _currentSeg,
            status: 'cancelled',
          )));
    }
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  void dispose() {
    // Servis modunda takip arka planda SÜRER (bilerek durdurulmaz);
    // yalnızca ekran dinleyicileri temizlenir.
    _gpsSub?.cancel();
    _simTimer?.cancel();
    _beltTimer?.cancel();
    _snoozeTimer?.cancel();
    _uiTicker?.cancel();
    LiveActivityService.instance.end(); // iOS dışında no-op
    if (_serviceMode) TrackingController.removeListener(_onServiceData);
    super.dispose();
  }

  /// Zaman çizelgesi için: mevcut konumun hattaki hangi durağa denk geldiği.
  int get _currentSeg {
    final pos = _pos;
    if (pos == null || _geoPoints.length < 2) return 0;
    final proj = geo.projectOntoLine(
      geo.LatLng(pos.latitude, pos.longitude),
      _geoPoints,
    );
    var seg = proj.segmentIndex;
    if (proj.t >= 0.999 && seg < _geoPoints.length - 2) seg += 1;
    return seg.clamp(0, _route.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final status = _status;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Başlık
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Canlı Takip', style: text.headlineMedium),
                  ),
                  if (kShowSimulateButton && !_simulating) ...[
                    IconButton(
                      tooltip: 'Simüle et (test)',
                      onPressed: _toggleSimulation,
                      icon: const Icon(Icons.play_circle_outline,
                          color: VigilantColors.onSurfaceVariant),
                    ),
                    IconButton(
                      tooltip: 'Yeraltı (sinyal yok) simüle et',
                      onPressed: _toggleUndergroundSimulation,
                      icon: const Icon(Icons.subway_outlined,
                          color: VigilantColors.onSurfaceVariant),
                    ),
                  ],
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: VigilantColors.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: VigilantColors.primary.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Text(
                      _simulating ? '$_lineLabel · SİM' : _lineLabel,
                      style: text.labelMedium
                          ?.copyWith(color: VigilantColors.primary),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                _statusLine(status),
                style: text.bodyMedium?.copyWith(
                  color: (_permissionDenied && !_simulating) ||
                          status?.state == JourneyState.signalLost
                      ? VigilantColors.tertiaryContainer
                      : VigilantColors.onSurfaceVariant,
                ),
              ),
            ),
            if (status?.state == JourneyState.signalLost)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: VigilantColors.tertiaryContainer
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: VigilantColors.tertiaryContainer
                          .withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.wifi_off_rounded,
                          size: 15, color: VigilantColors.tertiaryContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Yeraltı modu — öğrenilmiş sürelerle tahmini takip. '
                          'Sinyal gelince otomatik düzeltilir.',
                          style: text.labelMedium?.copyWith(
                              color: VigilantColors.tertiaryContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_serviceMode)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: Row(
                  children: [
                    const Icon(Icons.shield_outlined,
                        size: 14, color: VigilantColors.secondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Arka plan takibi aktif — uygulamadan çıksan bile sürer.',
                        style: text.labelMedium
                            ?.copyWith(color: VigilantColors.secondary),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            // Canlı harita
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: SizedBox(
                  height: 180,
                  child: RouteMap(
                    line: _line,
                    boardingStopId: widget.payload?.boardingStopId,
                    targetStopId: widget.payload?.targetStopId,
                    currentLocation: _pos,
                    autoFit: false,
                    initialZoom: 12,
                    // Geçilen kısım soluk, kalan kısım parlak çizilir.
                    showProgress: true,
                    // Ortala butonu: konumu izle; elle kaydırınca izleme durur.
                    followButton: true,
                    initialFollow: true,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Kalan durak halkası + ETA/mesafe (durum yüklenene dek iskelet).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: status == null
                  ? const _ProgressHeroSkeleton()
                  : _ProgressHero(
                      status: status,
                      totalStops:
                          _route.isNotEmpty ? _route.length - 1 : 0,
                      distanceText:
                          _formatDistance(status.distanceToTargetMeters) ?? '—',
                    ),
            ),
            if (_snoozeCountdown case final countdown?) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _SnoozeChip(countdown: countdown),
              ),
            ],
            const SizedBox(height: 20),
            // Dikey zaman çizelgesi
            Expanded(
              child: _route.isEmpty
                  ? _EmptyTimeline(targetName: _targetStopName)
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      children: _buildTimeline(),
                    ),
            ),
            // Kaydırarak durdur (kaza ile iptali önler). Alarm zaten
            // durdurulduysa bu "İndim" olur ve yolculuğu tamamlanmış kaydeder;
            // aksi halde yolculuğu iptal eder.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: _alarmAcknowledged
                  ? SlideToAction(
                      key: const ValueKey('slide-arrived'),
                      label: 'İndim — bitirmek için kaydır',
                      icon: Icons.check_circle_outline,
                      fillColor: VigilantColors.secondary,
                      onConfirmed: _completeJourney,
                    )
                  : SlideToAction(
                      key: const ValueKey('slide-cancel'),
                      label: 'Durdurmak için kaydır',
                      icon: Icons.notifications_off_outlined,
                      fillColor: VigilantColors.accentBlue,
                      onConfirmed: _cancelJourney,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildTimeline() {
    final seg = _currentSeg;
    final last = _route.length - 1;
    final arrived = _status?.state == JourneyState.arrived;
    final entries = <Widget>[];
    for (var i = 0; i < _route.length; i++) {
      final name = _route[i].name;
      if (arrived && i == last) {
        entries.add(_TimelineEntry.current(
          label: 'VARDINIZ',
          name: name,
          note: 'İyi yolculuklar',
        ));
      } else if (i == last) {
        entries.add(_TimelineEntry.target(label: 'Hedef Durak', name: name));
      } else if (i < seg) {
        entries.add(_TimelineEntry.passed(time: 'Geçildi', name: name));
      } else if (i == seg) {
        entries.add(_TimelineEntry.current(
          label: 'ŞU ANKİ KONUM',
          name: name,
          note: '${_route[(i + 1).clamp(0, last)].name} yönünde',
        ));
      } else {
        entries.add(_TimelineEntry.future(name: name, opacity: 0.6));
      }
    }
    return entries;
  }
}

class _EmptyTimeline extends StatelessWidget {
  const _EmptyTimeline({required this.targetName});

  final String targetName;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // STOPİ haritayı işaret ediyor (paket pozu, süzülerek).
            const AnimatedMascot(MascotAssets.poseHarita, height: 132),
            const SizedBox(height: 12),
            Text(
              'Bu yolculuk için hat verisi yok.\nArama ekranından bir durak '
              'seçerek canlı takibi başlatabilirsin.',
              textAlign: TextAlign.center,
              style: text.bodyMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Kalan durak halkası (sol) + ETA/mesafe kartları (sağ).
class _ProgressHero extends StatelessWidget {
  const _ProgressHero({
    required this.status,
    required this.totalStops,
    required this.distanceText,
  });

  final JourneyStatus status;
  final int totalStops;
  final String distanceText;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final remaining = status.stopsRemaining;
    final progress =
        totalStops <= 0 ? 0.0 : (totalStops - remaining) / totalStops;
    final etaMin = (status.etaSeconds / 60).ceil();
    return Row(
      children: [
        ProgressRing(
          progress: progress,
          size: 128,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$remaining',
                style: text.headlineLarge?.copyWith(fontSize: 40, height: 1),
              ),
              Text(
                'DURAK KALDI',
                style: text.labelSmall?.copyWith(
                  color: VigilantColors.onSurfaceVariant,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            children: [
              _MiniStat(
                icon: Icons.schedule,
                iconColor: VigilantColors.secondary,
                label: 'TAHMİNİ VARIŞ',
                value: status.state == JourneyState.arrived ? '0' : '$etaMin',
                unit: 'dk',
              ),
              const SizedBox(height: 12),
              _MiniStat(
                icon: Icons.route_outlined,
                iconColor: VigilantColors.tertiaryContainer,
                label: 'KALAN MESAFE',
                value: distanceText,
                unit: '',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProgressHeroSkeleton extends StatelessWidget {
  const _ProgressHeroSkeleton();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 128,
          height: 128,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: VigilantColors.surfaceContainerHigh,
          ),
          child: const Center(
            child: SkeletonBox(width: 40, height: 34, radius: 8),
          ),
        ),
        const SizedBox(width: 16),
        const Expanded(
          child: Column(
            children: [
              SkeletonTile(height: 58),
              SizedBox(height: 12),
              SkeletonTile(height: 58),
            ],
          ),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.unit,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GlassPanel(
      borderRadius: 18,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 18, color: iconColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelSmall?.copyWith(
                    color: VigilantColors.onSurfaceVariant,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 2),
                RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    text: value,
                    style:
                        text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                    children: [
                      if (unit.isNotEmpty)
                        TextSpan(
                          text: ' $unit',
                          style: text.labelMedium?.copyWith(
                            color: VigilantColors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Ertele sürerken görünen sayaç çipi ("Alarm mm:ss sonra tekrar çalacak").
class _SnoozeChip extends StatelessWidget {
  const _SnoozeChip({required this.countdown});

  final String countdown;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: VigilantColors.tertiaryContainer.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: VigilantColors.tertiaryContainer.withValues(alpha: 0.35),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.snooze,
              size: 18, color: VigilantColors.tertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Alarm ertelendi',
              style: text.labelLarge
                  ?.copyWith(color: VigilantColors.tertiaryContainer),
            ),
          ),
          Text(
            countdown,
            style: text.headlineSmall?.copyWith(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: VigilantColors.tertiaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry._({
    required this.marker,
    required this.body,
    this.opacity = 1,
    this.trackActive = false,
  });

  factory _TimelineEntry.passed({required String time, required String name}) {
    return _TimelineEntry._(
      opacity: 0.4,
      trackActive: true,
      marker: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: VigilantColors.surfaceContainer,
          border: Border.all(
            color: VigilantColors.primary.withValues(alpha: 0.5),
            width: 2,
          ),
        ),
        child: const Icon(Icons.check, size: 14, color: VigilantColors.primary),
      ),
      body: _TimelineBody(caption: time, name: name),
    );
  }

  factory _TimelineEntry.current({
    required String label,
    required String name,
    required String note,
  }) {
    return _TimelineEntry._(
      trackActive: true,
      marker: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: VigilantColors.primary,
          boxShadow: [
            BoxShadow(
              color: VigilantColors.primary.withValues(alpha: 0.5),
              blurRadius: 16,
            ),
          ],
        ),
        child: Center(
          child: Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: VigilantColors.onPrimary,
            ),
          ),
        ),
      ),
      body: _TimelineBody(
        caption: label,
        captionColor: VigilantColors.primary,
        name: name,
        nameSize: 24,
        note: note,
      ),
    );
  }

  factory _TimelineEntry.target({
    required String label,
    required String name,
  }) {
    return _TimelineEntry._(
      marker: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: VigilantColors.surfaceContainer,
          border: Border.all(
            color: VigilantColors.tertiaryContainer,
            width: 2,
          ),
        ),
        child: const Icon(Icons.flag,
            size: 14, color: VigilantColors.tertiaryContainer),
      ),
      body: _TimelineBody(
          caption: label, name: name, nameWeight: FontWeight.w600),
    );
  }

  factory _TimelineEntry.future({
    required String name,
    required double opacity,
  }) {
    return _TimelineEntry._(
      opacity: opacity,
      marker: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: VigilantColors.surfaceContainer,
          border: Border.all(
            color: VigilantColors.outline.withValues(alpha: 0.3),
            width: 2,
          ),
        ),
        child: Center(
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: VigilantColors.outline.withValues(alpha: 0.3),
            ),
          ),
        ),
      ),
      body: _TimelineBody(name: name, muted: true),
    );
  }

  final Widget marker;
  final Widget body;
  final double opacity;
  final bool trackActive;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Column(
              children: [
                marker,
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    color: trackActive
                        ? VigilantColors.primary
                        : VigilantColors.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 28),
                child: body,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimelineBody extends StatelessWidget {
  const _TimelineBody({
    this.caption,
    this.captionColor,
    required this.name,
    this.nameSize,
    this.nameWeight,
    this.note,
    this.muted = false,
  });

  final String? caption;
  final Color? captionColor;
  final String name;
  final double? nameSize;
  final FontWeight? nameWeight;
  final String? note;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (caption != null)
          Text(
            caption!,
            style: text.labelMedium?.copyWith(
              color: captionColor ?? VigilantColors.onSurfaceVariant,
              fontWeight:
                  captionColor != null ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        Text(
          name,
          style: text.bodyLarge?.copyWith(
            fontSize: nameSize,
            fontWeight:
                nameWeight ?? (nameSize != null ? FontWeight.w700 : null),
            color: muted ? VigilantColors.onSurfaceVariant : null,
          ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              note!,
              style: text.labelLarge?.copyWith(
                color: VigilantColors.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }
}
