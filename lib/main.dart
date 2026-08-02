import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import 'src/data/journey_payload.dart';
import 'src/data/models.dart';
import 'src/screens/data_bootstrap_screen.dart';
import 'src/screens/live_tracking_screen.dart';
import 'src/screens/onboarding_screen.dart';
import 'src/screens/permission_gate_screen.dart';
import 'src/services/ad_service.dart';
import 'src/services/alarm_notifications.dart';
import 'src/services/bus_data_service.dart';
import 'src/services/cloud_learning_service.dart';
import 'src/services/firebase_bootstrap.dart';
import 'src/services/home_widget_launcher.dart';
import 'src/services/home_widget_service.dart';
import 'src/services/permission_service.dart';
import 'src/services/telemetry.dart';
import 'src/services/tracking_service.dart';
import 'src/state/journey_provider.dart';
import 'src/state/onboarding_provider.dart';
import 'src/state/settings_provider.dart';
import 'src/theme/app_theme.dart';
import 'src/util/platform_check.dart';
import 'src/widgets/bottom_nav_shell.dart';
import 'src/widgets/mascot.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Arka plan servisi <-> UI iletişim portu (yalnızca Android'de etkin).
  TrackingController.ensureInitialized();
  await AlarmNotifications.init();
  // AdMob SDK'sını arka planda başlat (mobil dışı platformda no-op).
  unawaited(AdService.instance.init());
  // Firebase.initializeApp BEKLENEREK çağrılır (yerel, hızlı) ki okuma
  // sağlayıcıları hazır olmayan FirebaseAuth'a düşmesin. Anonim giriş (ağ)
  // bunun içinde bloklamadan yapılır.
  await bootstrapFirebase();
  // Çökme raporlama + analitik (Firebase'den sonra; alarm güvenilirlik ölçümü).
  await Telemetry.init();
  runApp(const ProviderScope(child: StopAlertApp()));
}

class StopAlertApp extends StatelessWidget {
  const StopAlertApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StopAlert',
      debugShowCheckedModeBanner: false,
      // Vigilant Dark tasarım sistemi koyu tema üzerine kurulu (bkz. PLAN.md).
      theme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const _RootGate(),
    );
  }
}

/// Kök akış: onboarding -> (Android) izin kapısı -> devam eden yolculuk
/// varsa Canlı Takip, yoksa ana ekran.
class _RootGate extends ConsumerStatefulWidget {
  const _RootGate();

  @override
  ConsumerState<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends ConsumerState<_RootGate>
    with WidgetsBindingObserver {
  bool? _permissionsOk = isMobileDevice ? null : true;

  /// Otobüs veri paketi hazır mı: null=kontrol ediliyor, false=dolum ekranı
  /// (ilk açılış indirme), true=devam. Mobil dışında hep true (atlanır).
  bool? _dataReady = isMobileDevice ? null : true;

  StreamSubscription<Uri?>? _widgetClicks;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (isMobileDevice) _checkData();
    _refreshPermissionStatus();
    _flushCloudLearning();
    _listenHomeWidget();
  }

  /// Ana ekran widget'ından gelen dokunuşlar.
  ///
  /// Takip sürerken widget'a dokunmak zaten [_ResumeGate] üzerinden Canlı
  /// Takip'e düşer; burada yalnızca "Alarm kur" bağlantısı karşılanır.
  Future<void> _listenHomeWidget() async {
    if (!isAndroidDevice) return;
    // Kısayollara basılınca uygulama açılmadan alarm başlasın diye arka plan
    // giriş noktasını kaydet.
    unawaited(HomeWidget.registerInteractivityCallback(
        homeWidgetBackgroundCallback));
    _handleWidgetUri(await HomeWidgetService.initialLaunchUri());
    _widgetClicks = HomeWidgetService.clicks.listen(_handleWidgetUri);
    unawaited(_refreshWidgetShortcuts());
  }

  /// Widget'ın boş durumundaki iki kısayolu tazele: en son yolculuk ve ilk
  /// favori rota. Uygulama her öne geldiğinde güncellenir.
  Future<void> _refreshWidgetShortcuts() async {
    if (!isAndroidDevice) return;
    try {
      final shortcuts = <WidgetShortcut>[];
      // 1) Son yolculuk (takip başlarken hatırlandı).
      final last = await HomeWidgetService.lastRoute();
      if (last != null) shortcuts.add(last);
      // 2) Favori rota — son yolculukla aynıysa atlanır.
      final favorites = await ref
          .read(favoritesStreamProvider.future)
          .timeout(_widgetDataTimeout);
      for (final f in favorites) {
        if (shortcuts.any((s) =>
            s.lineId == f.lineId && s.targetStopId == f.targetStopId)) {
          continue;
        }
        shortcuts.add(WidgetShortcut(
          title: f.targetStopName,
          subtitle: '${f.boardingStopName} → ${f.targetStopName}',
          lineCode: f.lineCode,
          color: colorHex(lineTypeColor(
              LineType.values.asNameMap()[f.lineTypeName] ?? LineType.bus)),
          lineId: f.lineId,
          boardingStopId: f.boardingStopId,
          targetStopId: f.targetStopId,
        ));
        if (shortcuts.length == 2) break;
      }
      await HomeWidgetService.setShortcuts(shortcuts);
    } catch (_) {
      // Favori yoksa/okunamadıysa widget yalnızca "Alarm kur" gösterir.
    }
  }

  static const _widgetDataTimeout = Duration(seconds: 8);

  void _handleWidgetUri(Uri? uri) {
    if (uri == null || !mounted) return;
    if (uri.path == HomeWidgetService.pathNewAlarm) {
      // Rotalar sekmesi: hat/durak aranıp alarm kurulur.
      ref.read(bottomNavIndexProvider.notifier).state = 1;
    }
  }

  /// İlk açılışta yerel otobüs DB'si yoksa dolum ekranını göster; varsa arka
  /// planda aç/güncelle ve akışa hemen devam et.
  Future<void> _checkData() async {
    final hasLocal = await BusDataService.instance.hasLocal();
    if (!mounted) return;
    if (hasLocal) {
      unawaited(BusDataService.instance.ensureReady());
      setState(() => _dataReady = true);
    } else {
      setState(() => _dataReady = false);
    }
  }

  /// Bekleyen anonim segment gözlemlerini (rıza varsa) buluta gönder; yoksa
  /// kuyruğu temizle. Başlangıçta ve her öne gelişte çalışır.
  Future<void> _flushCloudLearning() async {
    try {
      final settings = await ref.read(settingsProvider.future);
      await ref
          .read(cloudLearningServiceProvider)
          .flushQueue(consent: settings.contributeToCloud);
    } catch (_) {
      // Ağ/oturum yok: sonraki öne gelişte tekrar denenir.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _widgetClicks?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionStatus();
      _flushCloudLearning();
      // Yeni favori/yolculuk widget kısayollarına yansısın.
      unawaited(_refreshWidgetShortcuts());
    }
  }

  Future<void> _refreshPermissionStatus() async {
    if (!isMobileDevice) {
      if (mounted) setState(() => _permissionsOk = true);
      return;
    }
    final report = await PermissionService().check();
    if (!mounted) return;
    setState(() {
      final current = _permissionsOk;
      if (current == null) {
        // İlk açılış: izinler tamsa kapıyı hiç gösterme.
        _permissionsOk = report.criticalGranted;
      } else if (current && !report.criticalGranted) {
        // Kullanımdayken izin geri alındı: kapı yeniden öne gelsin.
        _permissionsOk = false;
      }
      // Kapı görünürken (false) otomatik true'ya ÇEKME: ayarlardan her
      // dönüşte sayfanın aniden kapanıp kullanıcıyı yarıda bırakmaması için
      // kapı yalnızca kendi "Devam et" butonuyla (onCompleted) kapanır.
    });
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = ref.watch(onboardingProvider);
    return onboarding.when(
      loading: () => const _Splash(),
      error: (_, __) => const BottomNavShell(),
      data: (done) {
        if (!done) return const OnboardingScreen();
        // İlk açılış: otobüs veri paketi inene kadar dolum ekranı.
        final dataReady = _dataReady;
        if (dataReady == null) return const _Splash();
        if (!dataReady) {
          return DataBootstrapScreen(
            onCompleted: () {
              if (mounted) setState(() => _dataReady = true);
            },
          );
        }
        final permissionsOk = _permissionsOk;
        if (permissionsOk == null) return const _Splash();
        if (!permissionsOk) {
          // Arka plan takibi için zorunlu izinler ("Her zaman izin ver")
          // tamamlanmadan uygulama akışı başlamaz.
          return PermissionGateScreen(
            onCompleted: () {
              if (mounted) setState(() => _permissionsOk = true);
            },
          );
        }
        return const _ResumeGate();
      },
    );
  }
}

/// Uygulama yeniden açıldığında: arka plan servisi hâlâ koşuyorsa doğrudan
/// Canlı Takip'e dön (kaldığı yerden devam).
class _ResumeGate extends StatelessWidget {
  const _ResumeGate();

  @override
  Widget build(BuildContext context) {
    if (!isAndroidDevice) return const BottomNavShell();
    return FutureBuilder<JourneyPayload?>(
      future: TrackingController.activeJourney(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _Splash();
        }
        final payload = snap.data;
        if (payload != null) {
          return LiveTrackingScreen(payload: payload, restored: true);
        }
        return const BottomNavShell();
      },
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // STOPİ karşılıyor (logo yalnızca uygulama simgesinde kullanılır).
            const Mascot(MascotAssets.hero, height: 150),
            const SizedBox(height: 28),
            const CircularProgressIndicator(color: VigilantColors.primary),
          ],
        ),
      ),
    );
  }
}
