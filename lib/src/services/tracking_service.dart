import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../data/journey_payload.dart';
import '../engine/geo.dart' as geo;
import '../engine/journey_engine.dart';
import '../engine/stop_detector.dart';
import '../util/platform_check.dart';
import 'alarm_notifications.dart';
import 'permission_service.dart';
import 'segment_learning_store.dart';

/// Servis komutları (UI -> arka plan isolate).
abstract final class TrackingCommands {
  static const stopAlarm = 'stopAlarm'; // alarmı sustur + servisi bitir
  static const dismissAlarm = 'dismissAlarm'; // alarmı sustur, TAKİBE devam et
  static const snooze = 'snooze'; // alarmı sustur, takibe devam (ertele)
  static const simulate = 'simulate'; // rota üzerinde sahte sürüş (test)
  static const simulateUnderground =
      'simulateUnderground'; // yeraltı (sinyal yok) ölü hesabı testi
}

/// Arka plan isolate giriş noktası.
@pragma('vm:entry-point')
void trackingTaskCallback() {
  FlutterForegroundTask.setTaskHandler(TrackingTaskHandler());
}

/// Konum tipli ön plan servisinde koşan takip görevi.
///
/// Uygulama kapansa, ekran kilitlense, son uygulamalardan atılsa bile:
/// - GPS akışını dinler, [JourneyEngine] ile durumu günceller,
/// - kalıcı bildirimi (şu anki/sonraki durak, ETA, mesafe) sürekli yeniler,
/// - alarm eşiğinde tam ekran insistent alarmı çalar,
/// - GPS ölse dahi emniyet kemeri (planlanan süre) alarmı zorlar.
class TrackingTaskHandler extends TaskHandler {
  JourneyEngine? _engine;
  JourneyPayload? _payload;
  StreamSubscription<Position>? _sub;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  final StopDetector _stopDetector = StopDetector();
  Timer? _simTimer;
  double _simProgress = 0;
  DateTime _start = DateTime.now();
  DateTime? _snoozeUntil;
  bool _alarmActive = false;

  /// Kullanıcı "yaklaşma" alarmını kaydırarak durdurdu ama henüz VARMADI:
  /// takip sürer, alarm hedefe fiilen varana kadar bir daha çalmaz.
  bool _alarmAcknowledged = false;
  bool _arrived = false;

  /// Yeraltı simülasyonu sürüyor (onRepeatEvent GPS sondasını atlar).
  bool _underground = false;

  /// Öğrenilen segment süreleri deposuna bir kez yazıldı mı (varışta).
  bool _learnRecorded = false;

  /// En son GERÇEK GPS güncellemesinin zamanı (yeraltı/sinyal-yok tespiti).
  DateTime _lastGpsAt = DateTime.now();
  TrackingUpdate? _last;

  int get _elapsedSec => DateTime.now().difference(_start).inSeconds;

  /// GPS akışı bir süredir sessizse (tünel/yeraltı ya da uzun duruş) true.
  bool get _gpsStale =>
      DateTime.now().difference(_lastGpsAt) > const Duration(seconds: 14);

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final raw =
        await FlutterForegroundTask.getData<String>(key: 'journey_payload');
    final payload = JourneyPayload.tryDecode(raw);
    if (payload == null) {
      FlutterForegroundTask.stopService();
      return;
    }
    _payload = payload;
    // ÖĞRENME: bu hatta önceki yolculuklardan öğrenilmiş segment sürelerini
    // yükle; yeraltı ölü hesabı statik GTFS yerine bunları kullanır.
    final learner = await SegmentLearningStore.load();
    _engine = JourneyEngine(
      line: payload.line,
      boardingStopId: payload.boardingStopId,
      targetStopId: payload.targetStopId,
      alarmDistanceMeters: payload.alarmDistanceMeters,
      alarmStopsThreshold: payload.alarmStopsThreshold,
      learner: learner,
    );
    _start = DateTime.now();
    _lastGpsAt = DateTime.now();
    await AlarmNotifications.init();

    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen(_onPosition, onError: (_) {});

    // İvmeölçer: yeraltında (GPS yokken) durak sayımı için. Arka plan
    // isolate'te akış çalışmayabilir; hata olursa zaman sayacı tek başına
    // yeter (füzyonda temkinli kazanır).
    try {
      _accelSub = accelerometerEventStream(
        samplingPeriod: const Duration(milliseconds: 100),
      ).listen(_onAccelerometer, onError: (_) {});
    } catch (_) {}

    // İlk konumu hemen almayı dene (akış ilk veriyi geciktirebilir).
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _onPosition(p);
    } catch (_) {}
  }

  /// İvmeölçer örneği: büyüklük varyansından durak durması tespit et.
  /// Yalnızca GPS sessizken (yeraltı) durak SAYIMINA döner.
  void _onAccelerometer(AccelerometerEvent e) {
    final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    final t = DateTime.now().difference(_start);
    final departed = _stopDetector.feed(mag, t);
    if (!departed || _arrived || !_gpsStale) return;
    final engine = _engine;
    if (engine == null) return;
    final status = engine.onStopDetected(Duration(seconds: _elapsedSec));
    _reactToStatus(status);
    _publish(status, _last?.lat ?? 0, _last?.lon ?? 0);
  }

  void _onPosition(Position p) =>
      _handlePoint(p.latitude, p.longitude, p.accuracy);

  void _handlePoint(double lat, double lon, double accuracyMeters) {
    final engine = _engine;
    final payload = _payload;
    if (engine == null || payload == null || _arrived) return;

    _lastGpsAt = DateTime.now(); // GPS taze — yeraltı ölü hesabı geri çekilir

    final status = engine.update(GpsSample(
      point: geo.LatLng(lat, lon),
      accuracyMeters: accuracyMeters,
      elapsed: Duration(seconds: _elapsedSec),
    ));

    _reactToStatus(status);
    _publish(status, lat, lon);
  }

  /// Bir duruma tepki ver: yaklaşma alarmı, varış (öğrenme + alarm). GPS ve
  /// yeraltı (ölü hesap/ivmeölçer) yolları bu ortak mantığı paylaşır.
  void _reactToStatus(JourneyStatus status) {
    final payload = _payload;
    if (payload == null) return;

    // "Yaklaşma" alarmı: kullanıcı bir kez durdurduysa (acknowledged) tekrar
    // çalmaz — takip sürer ve varışta ekran kendiliğinden ilerler.
    if (status.state == JourneyState.approaching &&
        !_alarmActive &&
        !_alarmAcknowledged) {
      final now = DateTime.now();
      if (_snoozeUntil == null || now.isAfter(_snoozeUntil!)) {
        _fireAlarm(
            payload.targetStopName,
            'Kalan: ${status.stopsRemaining} durak · '
            '${_fmtDist(status.distanceToTargetMeters)}');
      }
    }
    if (status.state == JourneyState.arrived) {
      _arrived = true;
      _learnFromJourney(); // ÖĞRENME: ölçülen segment sürelerini modele işle
      // Yaklaşma alarmı zaten susturulduysa varışta yeniden çaldırma; ekran
      // "arrived" durumunu görüp İndin sayfasına kendiliğinden geçer.
      if (!_alarmActive && !_alarmAcknowledged) {
        _fireAlarm(payload.targetStopName, 'Vardın — inme zamanı');
      }
    }
  }

  /// Bu yolculukta iyi GPS altında ölçülen segment sürelerini öğrenme deposuna
  /// yazar (yalnızca bir kez). Model bir sonraki yolculukta daha isabetli olur.
  void _learnFromJourney() {
    if (_learnRecorded) return;
    final engine = _engine;
    if (engine == null) return;
    _learnRecorded = true;
    final obs = engine.observations();
    if (obs.isNotEmpty) unawaited(SegmentLearningStore.record(obs));
  }

  /// Cihazda uçtan uca test: GPS yerine rota üzerinde sabit hızla ilerleyen
  /// sahte konumlar üretir. Bildirim güncellemesi, alarm, tam ekran intent
  /// dahil tüm zincir GERÇEK servis yolundan çalışır.
  void _startSimulation() {
    if (_simTimer != null || _arrived) return;
    final stops = _engine?.routeStops ?? const [];
    if (stops.length < 2) return;
    _sub?.cancel();
    _sub = null;
    _simProgress = 0;
    final segCount = stops.length - 1;
    _simTimer = Timer.periodic(const Duration(milliseconds: 700), (timer) {
      if (_arrived) {
        timer.cancel();
        _simTimer = null;
        return;
      }
      _simProgress = (_simProgress + 0.14).clamp(0.0, segCount.toDouble());
      final seg = _simProgress.floor().clamp(0, segCount - 1);
      final frac = _simProgress - seg;
      final a = stops[seg];
      final b = stops[seg + 1];
      _handlePoint(
        a.lat + (b.lat - a.lat) * frac,
        a.lon + (b.lon - a.lon) * frac,
        8,
      );
    });
  }

  /// Cihazda YERALTI testi: GPS'i keser, zaman sayacıyla (öğrenilmiş segment
  /// süreleri) hızlandırılmış ölü hesap sürer. "Sinyal yok" bildirimi, kalan
  /// durak azalışı, belirsizlikle öne çekilen alarm ve varış zinciri gerçek
  /// servis yolundan çalışır.
  void _startUndergroundSimulation() {
    if (_simTimer != null || _arrived) return;
    final engine = _engine;
    final stops = engine?.routeStops ?? const [];
    if (engine == null || stops.length < 2) return;
    // Binişi bir kez besle (motoru aktive et), sonra GPS'i kes.
    _handlePoint(stops.first.lat, stops.first.lon, 8);
    _sub?.cancel();
    _sub = null;
    _underground = true;
    var virtualSec = 0;
    _simTimer = Timer.periodic(const Duration(milliseconds: 600), (timer) {
      if (_arrived) {
        timer.cancel();
        _simTimer = null;
        return;
      }
      virtualSec += 20; // her tik 20 sn ilerlet (hızlı demo)
      final status = engine.updateNoSignal(Duration(seconds: virtualSec));
      _reactToStatus(status);
      _publish(status, stops.first.lat, stops.first.lon);
    });
  }

  void _fireAlarm(String stopName, String body) {
    _alarmActive = true;
    AlarmNotifications.showAlarm(stopName: stopName, body: body);
    // Kalıcı bildirimi de ALARM durumuna çevir: alarm kanalı OEM tarafından
    // kısıtlansa bile kullanıcıya görünür bir işaret kalsın.
    FlutterForegroundTask.updateService(
      notificationTitle: 'ALARM · $stopName',
      notificationText: body,
    );
    // Kilitliyken tam ekran intent uygulamayı açar; açıksa da alarma geç.
    // (Arka plandan aktivite açma, "uygulama üzerinde göster" izni verilmişse
    // ayrıca garanti altına girer.)
    FlutterForegroundTask.launchApp('/');
  }

  void _publish(JourneyStatus status, double lat, double lon) {
    final currentStopName = _currentStopName(status);
    final update = TrackingUpdate(
      state: status.state.name,
      stopsRemaining: status.stopsRemaining,
      etaSeconds: status.etaSeconds,
      distanceMeters: status.distanceToTargetMeters,
      currentStopName: currentStopName,
      nextStopName: status.nextStopName,
      lat: lat,
      lon: lon,
      alarmActive: _alarmActive,
      confidence: status.confidence,
    );
    _last = update;

    // Kalıcı bildirim: şu anki durum + sonraki durak + ETA + mesafe.
    if (status.state == JourneyState.waiting) {
      // Kullanıcı henüz hatta değil (ör. evden biniş durağına gidiyor).
      FlutterForegroundTask.updateService(
        notificationTitle: 'StopAlert · binişe gidiliyor',
        notificationText: 'Biniş: ${_engine?.routeStops.first.name ?? ''} · '
            'takip binişte başlayacak',
      );
    } else {
      // Aktif / yaklaşıyor / sinyal yok: ilerleme çubuklu canlı bildirim.
      final code = _payload?.line.code ?? 'StopAlert';
      final total = (_engine?.routeStops.length ?? 1) - 1;
      final bar = _progressBar(status.stopsRemaining, total);
      final etaMin = (status.etaSeconds / 60).ceil();
      final signal =
          status.state == JourneyState.signalLost ? ' · sinyal yok' : '';
      FlutterForegroundTask.updateService(
        notificationTitle: '$code · ${status.stopsRemaining} durak kaldı$signal',
        notificationText: '$bar  Sonraki: ${status.nextStopName} · ~$etaMin dk',
      );
    }

    FlutterForegroundTask.sendDataToMain(update.encode());
    FlutterForegroundTask.saveData(key: 'last_update', value: update.encode());
  }

  String _currentStopName(JourneyStatus status) {
    final stops = _engine?.routeStops ?? const [];
    if (stops.isEmpty) return '';
    final targetIndex = stops.length - 1;
    final currentIndex =
        (targetIndex - status.stopsRemaining).clamp(0, targetIndex);
    return stops[currentIndex].name;
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    final engine = _engine;
    final payload = _payload;
    if (engine == null || payload == null || _arrived) return;

    // Yeraltı/sinyal-yok tespiti: GPS akışı bir süredir sessizse, GERÇEKTEN
    // GPS var mı diye taze bir konum dene. Alınabiliyorsa (durakta bekleme,
    // sinyal iyi) çapala; alınamıyorsa (tünel) zaman + ivmeölçer ölü hesabına
    // geç ve SINYAL_YOK yayınla.
    if (_gpsStale && _last != null && !_underground) {
      try {
        final p = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 6),
          ),
        );
        _onPosition(p);
      } catch (_) {
        final status = engine.updateNoSignal(Duration(seconds: _elapsedSec));
        _reactToStatus(status);
        if (!_arrived) _publish(status, _last!.lat, _last!.lon);
      }
    }

    // Emniyet kemeri: GPS gelmese bile planlanan süre dolunca alarmı zorla.
    if (!_alarmActive && engine.shouldForceAlarm(_elapsedSec)) {
      _fireAlarm(payload.targetStopName,
          'Planlanan yolculuk süresi doldu — inmeye hazırlan');
      final last = _last;
      if (last != null) {
        final forced = TrackingUpdate(
          state: last.state,
          stopsRemaining: last.stopsRemaining,
          etaSeconds: 0,
          distanceMeters: last.distanceMeters,
          currentStopName: last.currentStopName,
          nextStopName: last.nextStopName,
          lat: last.lat,
          lon: last.lon,
          alarmActive: true,
          confidence: last.confidence,
        );
        _last = forced;
        FlutterForegroundTask.sendDataToMain(forced.encode());
        // Uygulama kapalıysa: yeniden açılışta alarm ekranı otomatik açılsın
        // diye kalıcı duruma da yaz.
        FlutterForegroundTask.saveData(
            key: 'last_update', value: forced.encode());
      }
    }
  }

  /// Alarm bildirimi (insistent) servisten bağımsız yaşar: servis ölmeden
  /// ÖNCE iptali bekle, yoksa susturulamayan bir alarm kalabilir.
  Future<void> _cancelAlarmAndStop() async {
    await AlarmNotifications.cancelAlarm();
    await FlutterForegroundTask.stopService();
  }

  @override
  void onReceiveData(Object data) {
    if (data == TrackingCommands.stopAlarm) {
      _cancelAlarmAndStop();
    } else if (data == TrackingCommands.dismissAlarm) {
      // Alarmı sustur ama TAKİBİ SÜRDÜR: kullanıcı henüz durağa varmadı
      // (ör. 500 m kala alarmı durdurdu). Varışta ekran kendiliğinden geçer.
      AlarmNotifications.cancelAlarm();
      _alarmActive = false;
      _alarmAcknowledged = true;
      FlutterForegroundTask.updateService(
        notificationTitle: 'StopAlert · takip sürüyor',
        notificationText: 'Alarm durduruldu — durağa yaklaşınca haber vereceğiz',
      );
    } else if (data == TrackingCommands.snooze) {
      AlarmNotifications.cancelAlarm();
      _alarmActive = false;
      final minutes = _payload?.snoozeMinutes ?? 5;
      _snoozeUntil = DateTime.now().add(Duration(minutes: minutes));
    } else if (data == TrackingCommands.simulate) {
      _startSimulation();
    } else if (data == TrackingCommands.simulateUnderground) {
      _startUndergroundSimulation();
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop_tracking') {
      _cancelAlarmAndStop();
    }
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp('/');

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _simTimer?.cancel();
    await _sub?.cancel();
    await _accelSub?.cancel();
  }

  String _fmtDist(double m) => m >= 1000
      ? '${(m / 1000).toStringAsFixed(1)} km kaldı'
      : '${m.round()} m kaldı';

  /// Metin tabanlı ilerleme çubuğu (████░░░░) — foreground_task native
  /// ProgressBar sunmadığı için bildirim metnine gömülür.
  String _progressBar(int stopsRemaining, int totalStops, {int width = 10}) {
    if (totalStops <= 0) return '';
    final done = ((totalStops - stopsRemaining) / totalStops * width)
        .round()
        .clamp(0, width);
    return '${'█' * done}${'░' * (width - done)}';
  }
}

/// UI tarafından kullanılan servis yöneticisi.
abstract final class TrackingController {
  static bool _initialized = false;

  static void ensureInitialized() {
    if (!isAndroidDevice || _initialized) return;
    FlutterForegroundTask.initCommunicationPort();
    _initialized = true;
  }

  static void _initOptions() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'stopalert_tracking',
        channelName: 'Yolculuk Takibi',
        channelDescription:
            'Yolculuk sürerken kalan durak ve varış bilgisini gösterir',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // Emniyet kemeri kontrolü 10 sn'de bir.
        eventAction: ForegroundTaskEventAction.repeat(10000),
        allowWakeLock: true,
        allowAutoRestart: true,
        stopWithTask: false,
      ),
    );
  }

  /// Yolculuğu arka plan servisinde başlatır.
  static Future<bool> start(JourneyPayload payload) async {
    if (!isAndroidDevice) return false;
    ensureInitialized();
    _initOptions();
    final permissions = await PermissionService().check();
    if (!permissions.criticalGranted) return false;
    await FlutterForegroundTask.saveData(
        key: 'journey_payload', value: payload.encode());
    await FlutterForegroundTask.removeData(key: 'last_update');
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      serviceTypes: const [ForegroundServiceTypes.location],
      notificationTitle: 'StopAlert yolculuğu takip ediyor',
      notificationText: '${payload.targetStopName} için alarm kuruldu',
      notificationButtons: const [
        NotificationButton(id: 'stop_tracking', text: 'Takibi Durdur'),
      ],
      notificationInitialRoute: '/',
      callback: trackingTaskCallback,
    );
    return result is ServiceRequestSuccess;
  }

  static Future<void> stop() async {
    if (!isAndroidDevice) return;
    await AlarmNotifications.cancelAlarm();
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  static void sendCommand(String command) {
    if (!isAndroidDevice) return;
    FlutterForegroundTask.sendDataToTask(command);
  }

  static Future<bool> get isRunning async =>
      isAndroidDevice && await FlutterForegroundTask.isRunningService;

  /// Devam eden yolculuğun payload'ı (uygulama yeniden açıldığında).
  static Future<JourneyPayload?> activeJourney() async {
    if (!isAndroidDevice) return null;
    if (!await FlutterForegroundTask.isRunningService) return null;
    final raw =
        await FlutterForegroundTask.getData<String>(key: 'journey_payload');
    return JourneyPayload.tryDecode(raw);
  }

  /// Servisin yayınladığı son durum (ekran ilk açıldığında).
  static Future<TrackingUpdate?> lastUpdate() async {
    if (!isAndroidDevice) return null;
    final raw = await FlutterForegroundTask.getData<String>(key: 'last_update');
    return TrackingUpdate.tryDecode(raw);
  }

  static void addListener(void Function(Object) cb) {
    if (!isAndroidDevice) return;
    FlutterForegroundTask.addTaskDataCallback(cb);
  }

  static void removeListener(void Function(Object) cb) {
    if (!isAndroidDevice) return;
    FlutterForegroundTask.removeTaskDataCallback(cb);
  }
}
