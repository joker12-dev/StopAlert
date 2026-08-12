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
import '../engine/time_bucket.dart';
import '../services/alarm_notifications.dart';
import '../services/live_activity_service.dart';
import '../services/location_service.dart';
import '../services/prediction_log.dart';
import '../services/segment_learning_store.dart';
import '../services/telemetry.dart';
import '../services/tracking_service.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/platform_check.dart';
import '../widgets/glass_panel.dart';
import '../widgets/map_style_sheet.dart';
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
/// (bildirim + alarm + tam ekran intent dahil uçtan uca test).
///
/// DERLEME BAYRAĞINA BAĞLI, koda gömülü değil. Varsayılan KAPALI: mağazaya
/// giden pakette yolcuya "yolculuğu simüle et" demek kafa karıştırıyor.
/// Test/kayıt derlemesinde açmak için:
///
///     flutter build apk --release --dart-define=SIM_BUTTON=true
///
/// Böylece alarmın çaldığını otobüse binmeden gösterebiliyoruz (Play'in
/// arka plan konumu için istediği video), Play'e yüklenen AAB ise temiz
/// kalıyor — bayrağı elle açıp kapatmayı unutma riski ortadan kalkıyor.
const bool kShowSimulateButton = bool.fromEnvironment('SIM_BUTTON');

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

  /// Yolculuk BAŞLARKEN motorun verdiği kalan süre (saniye).
  ///
  /// Varışta gerçekleşen süreyle karşılaştırılıp deftere yazılır
  /// ([PredictionLog]): doğruluk ölçülmeden iyileştirilemez.
  int? _firstEtaSeconds;

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
    if (s != null) {
      _captureFirstEta(s);
      _syncLiveActivity(s);
    }
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
      lineColor: colorHex(color),
      targetStop: _targetStopName,
      stopsRemaining: status.stopsRemaining,
      nextStop: status.nextStopName,
      etaMinutes: (status.etaSeconds / 60).ceil(),
      state: status.state.name,
    );
  }

  /// Fiilen hedefe varıldıysa İndin sayfasına yalnızca bir kez geç.
  /// (Alarm ekranı açıkken bekler: kullanıcı önce alarmı kapatır.)
  void _maybeArrived() {
    if (_arrivedHandled || _alarmScreenOpen) return;
    _completeJourney();
  }

  /// Yolculuğu başarıyla tamamla: takibi/servisi durdur, İndin sayfasına geç.
  ///
  /// Temizlik işleri (telemetri, öğrenme, servisi durdurma) İndin sayfasına
  /// geçişi ASLA engellememeli: biri hata verirse kullanıcı ölü bir takip
  /// ekranında kalıyordu — alarm susuyor ama hiçbir şey olmuyordu.
  void _completeJourney() {
    if (_arrivedHandled) return;
    _arrivedHandled = true;
    try {
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
      _logPredictionAccuracy();
      _stopTracking();
      if (_serviceMode) unawaited(TrackingController.stop());
    } catch (_) {
      // Yut: aşağıdaki geçiş her hâlükârda yapılmalı.
    }
    _goToArrival();
  }

  /// İlk ANLAMLI tahmini bir kez sakla.
  ///
  /// BEKLEMEDE durumu sayılmaz: kullanıcı henüz hatta binmemiştir, o
  /// andaki süre yolculuğun değil binişe yürümenin tahminidir.
  void _captureFirstEta(JourneyStatus s) {
    if (_firstEtaSeconds != null) return;
    if (s.state == JourneyState.waiting || s.state == JourneyState.idle) {
      return;
    }
    if (s.etaSeconds <= 0) return;
    _firstEtaSeconds = s.etaSeconds;
  }

  /// Tahmin ↔ gerçek karşılaştırmasını deftere yaz.
  ///
  /// Simülasyonda YAZILMAZ: sanal saatle koşan bir yolculuk gerçek
  /// doğruluk hakkında hiçbir şey söylemez, defteri kirletir.
  void _logPredictionAccuracy() {
    if (_simulating) return;
    final predicted = _firstEtaSeconds;
    if (predicted == null) return;
    unawaited(PredictionLog.record(PredictionRecord(
      lineCode: _lineLabel,
      bucketCode: TimeBucket.of(_start).code,
      predictedSeconds: predicted,
      actualSeconds: _elapsedSec,
      at: DateTime.now(),
    )));
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
      _captureFirstEta(status);
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

  // ---- Alt panel (sürüklenebilir) ----
  //
  // Harita TAM EKRAN: yolculuk sırasında kullanıcının asıl baktığı şey nerede
  // olduğu. Sayısal bilgiler haritanın üstünde yüzen bir panelde durur ve
  // istenirse aşağı çekilip harita büyütülebilir.
  static const _minPanelFraction = 0.30;
  static const _maxPanelFraction = 0.82;
  double _panelFraction = 0.46;
  double _availableHeight = 0;

  @override
  Widget build(BuildContext context) {
    final status = _status;

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          _availableHeight = constraints.maxHeight;
          return Stack(
            children: [
              // TAM EKRAN canlı harita.
              Positioned.fill(
                child: RouteMap(
                  line: _line,
                  boardingStopId: widget.payload?.boardingStopId,
                  targetStopId: widget.payload?.targetStopId,
                  currentLocation: _pos,
                  autoFit: false,
                  initialZoom: 15,
                  // Geçilen kısım soluk, kalan kısım parlak çizilir.
                  showProgress: true,
                  // Ortala butonu: konumu izle; elle kaydırınca izleme durur.
                  followButton: true,
                  initialFollow: true,
                ),
              ),
              // ÜST katman: başlık, hat rozeti, durum satırı, uyarı çipleri.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(bottom: false, child: _topOverlay(status)),
              ),
              // ALT katman: kalan durak halkası, ETA/mesafe, duraklar, kaydır.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: (_availableHeight * _panelFraction)
                    .clamp(0.0, _availableHeight),
                child: _bottomPanel(status),
              ),
            ],
          );
        },
      ),
    );
  }

  /// "Sorun bildir" — yolculuk sırasında görülen veri hatasını bildirme.
  ///
  /// ŞİMDİLİK YALNIZCA TASARIM: seçim hiçbir yere gönderilmiyor, yalnızca
  /// telemetriye düşüyor. Gönderim ucu (Firestore koleksiyonu + moderasyon)
  /// sonra bağlanacak; o zamana kadar kullanıcıya "kaydedildi" demiyoruz,
  /// "aldık" bile demiyoruz — yalnızca teşekkür ediyoruz ki yanlış bir söz
  /// vermiş olmayalım.
  Future<void> _reportIssue() async {
    Haptics.light();
    final kind = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: VigilantColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        final text = Theme.of(context).textTheme;
        const options = <(String, IconData, String)>[
          ('wrong_stop', Icons.wrong_location_outlined,
              'Durak konumu yanlış'),
          ('missing_stop', Icons.add_location_alt_outlined,
              'Güzergâhta eksik durak var'),
          ('wrong_route', Icons.alt_route_outlined, 'Güzergâh yanlış çizilmiş'),
          ('bad_eta', Icons.schedule_outlined, 'Tahmini süre çok tutarsız'),
          ('alarm_late', Icons.notifications_off_outlined,
              'Alarm geç/erken çaldı'),
          ('other', Icons.more_horiz, 'Başka bir sorun'),
        ];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: VigilantColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
                child: Row(
                  children: [
                    const Icon(Icons.flag_outlined,
                        size: 18, color: VigilantColors.primary),
                    const SizedBox(width: 10),
                    Text('Sorun bildir', style: text.titleMedium),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '$_lineLabel · $_targetStopName',
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                ),
              ),
              for (final (id, icon, label) in options)
                ListTile(
                  leading:
                      Icon(icon, color: VigilantColors.onSurfaceVariant),
                  title: Text(label, style: text.bodyMedium),
                  onTap: () => Navigator.pop(context, id),
                ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
    if (kind == null || !mounted) return;
    Telemetry.log('issue_reported', {'kind': kind, 'line': _lineLabel});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content: Text('Teşekkürler — bildirimin bize ulaşacak.'),
      ));
  }

  /// Harita görünümü seçici — ortak sayfa (widgets/map_style_sheet.dart).
  Future<void> _pickMapStyle() async {
    if (await pickMapStyle(context, ref) && mounted) setState(() {});
  }

  /// Haritanın üstünde yüzen başlık bloğu.
  Widget _topOverlay(JourneyStatus? status) {
    final text = Theme.of(context).textTheme;
    final warn = (_permissionDenied && !_simulating) ||
        status?.state == JourneyState.signalLost;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      // OPAK: yarı saydam camda harita döşemeleri yazının arkasından
      // görünüyor ve metin okunmuyordu. Hareket hâlindeki bir haritada
      // okunabilirlik saydamlıktan önce gelir.
      child: Container(
        decoration: BoxDecoration(
          color: VigilantColors.surfaceContainer,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: const [
            BoxShadow(color: Color(0x59000000), blurRadius: 18, spreadRadius: 1),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Canlı Takip', style: text.titleLarge),
                ),
                // SİMÜLASYON DÜĞMELERİ YAYINDA GİZLİ (kShowSimulateButton
                // false): geliştirme aracıydı, yolcuya "yolculuğu simüle et"
                // demek kafa karıştırıyor. Geliştirirken bayrağı açmak yeter.
                if (kShowSimulateButton && !_simulating) ...[
                  _IconAction(
                    tooltip: 'Simüle et (test)',
                    icon: Icons.play_circle_outline,
                    onTap: _toggleSimulation,
                  ),
                  _IconAction(
                    tooltip: 'Yeraltı (sinyal yok) simüle et',
                    icon: Icons.subway_outlined,
                    onTap: _toggleUndergroundSimulation,
                  ),
                ],
                _IconAction(
                  tooltip: 'Harita görünümü',
                  icon: Icons.layers_rounded,
                  onTap: _pickMapStyle,
                ),
                // Sorun bildir — şimdilik yalnızca tasarım (bkz. _reportIssue).
                _IconAction(
                  tooltip: 'Sorun bildir',
                  icon: Icons.flag_outlined,
                  onTap: _reportIssue,
                ),
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(
                    color: VigilantColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: VigilantColors.primary.withValues(alpha: 0.25),
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
            const SizedBox(height: 4),
            Text(
              _statusLine(status),
              style: text.bodySmall?.copyWith(
                color: warn
                    ? VigilantColors.tertiaryContainer
                    : VigilantColors.onSurfaceVariant,
              ),
            ),
            if (status?.state == JourneyState.signalLost) ...[
              const SizedBox(height: 8),
              const _NoticeChip(
                icon: Icons.wifi_off_rounded,
                color: VigilantColors.tertiaryContainer,
                text: 'Yeraltı modu — öğrenilmiş sürelerle tahmini takip. '
                    'Sinyal gelince otomatik düzeltilir.',
              ),
            ],
            if (_serviceMode) ...[
              const SizedBox(height: 6),
              const _NoticeChip(
                icon: Icons.shield_outlined,
                color: VigilantColors.secondary,
                text: 'Arka plan takibi aktif — uygulamadan çıksan bile sürer.',
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Sürüklenebilir alt panel.
  Widget _bottomPanel(JourneyStatus? status) {
    return Container(
      decoration: const BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(color: Color(0x66000000), blurRadius: 24, spreadRadius: 2),
        ],
      ),
      child: Column(
        children: [
          // Tutamaç — paneli büyütüp küçültmek için.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) {
              if (_availableHeight == 0) return;
              setState(() {
                _panelFraction =
                    (_panelFraction - d.delta.dy / _availableHeight)
                        .clamp(_minPanelFraction, _maxPanelFraction);
              });
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: VigilantColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
          // Kalan durak halkası + ETA/mesafe.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: status == null
                ? const _ProgressHeroSkeleton()
                : _ProgressHero(
                    status: status,
                    totalStops: _route.isNotEmpty ? _route.length - 1 : 0,
                    distanceText:
                        _formatDistance(status.distanceToTargetMeters) ?? '—',
                  ),
          ),
          if (_snoozeCountdown case final countdown?) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _SnoozeChip(countdown: countdown),
            ),
          ],
          const SizedBox(height: 14),
          // Şu anki konum + gelecek duraklar. Panel küçükken kaydırılır,
          // büyütülünce hepsi görünür.
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
            padding: EdgeInsets.fromLTRB(
                20, 8, 20, 12 + MediaQuery.viewPaddingOf(context).bottom),
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
/// Üst paneldeki küçük ikon butonu (simülasyon, sorun bildir).
///
/// `IconButton` yerine var: varsayılan 48 px dokunma alanı üç butonu yan yana
/// koyunca başlık satırını taşırıyordu.
class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 20, color: VigilantColors.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Üst paneldeki tek satırlık uyarı şeridi (sinyal yok / arka plan takibi).
class _NoticeChip extends StatelessWidget {
  const _NoticeChip({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: color, height: 1.3),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressHero extends StatelessWidget {
  const _ProgressHero({
    required this.status,
    required this.totalStops,
    required this.distanceText,
  });

  final JourneyStatus status;
  final int totalStops;
  final String distanceText;

  // Harita artık TAM EKRAN: bu blok haritanın üstünde duruyor ve eski
  // boyutlarıyla panelin yarısını yiyip durak listesine yer bırakmıyordu.
  // Ölçüler okunaklılığı bozmadan sıkılaştırıldı.
  static const _ringSize = 96.0;

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
          size: _ringSize,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$remaining',
                style: text.headlineMedium?.copyWith(fontSize: 30, height: 1),
              ),
              Text(
                'DURAK',
                style: text.labelSmall?.copyWith(
                  fontSize: 9,
                  color: VigilantColors.onSurfaceVariant,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
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
              const SizedBox(height: 8),
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
          width: 96,
          height: 96,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: VigilantColors.surfaceContainerHigh,
          ),
          child: const Center(
            child: SkeletonBox(width: 34, height: 28, radius: 8),
          ),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Column(
            children: [
              SkeletonTile(height: 48),
              SizedBox(height: 8),
              SkeletonTile(height: 48),
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
      borderRadius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 9),
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
                        text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
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
        nameSize: 20,
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
            const SizedBox(width: 16),
            Expanded(
              child: Padding(
                // 28 idi: harita tam ekran olunca panel kısaldı ve listede
                // aynı anda yalnızca iki durak görünüyordu.
                padding: const EdgeInsets.only(bottom: 18),
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
