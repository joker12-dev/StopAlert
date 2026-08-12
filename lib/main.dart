import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:home_widget/home_widget.dart';

import 'src/data/journey_payload.dart';
import 'src/data/models.dart';
import 'src/data/transit_city.dart';
import 'src/screens/data_bootstrap_screen.dart';
import 'src/screens/live_tracking_screen.dart';
import 'src/screens/consent_screen.dart';
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
import 'src/state/city_provider.dart';
import 'src/state/journey_provider.dart';
import 'src/state/consent_provider.dart';
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
    // Veri kontrolü izin kapısından SONRA yapılır (bkz. build): şehir tahmini
    // konum gerektiriyor ve izin henüz istenmemiş olabilir.
    if (!isMobileDevice) _dataReady = true;
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

  /// İzin kapısı geçildikten sonra veri durumunu kontrol et.
  ///
  /// Şehir tahmini AKIŞI BEKLETMEZ (arka planda tazelenir): cihaz sabitken
  /// Android konum sağlayıcısını kısıyor ve bekleyen çağrı kullanıcıyı boş
  /// ekranda tutuyordu. Zaten veri paketi ekranı konuma bakmıyor — kullanıcı
  /// hangi şehri istiyorsa onun düğmesine basıyor.
  Future<void> _afterPermissions() async {
    unawaited(ref.read(cityProvider.notifier).refreshFromLocation());
    await _checkData();
  }

  /// İlk açılışta yerel otobüs DB'si yoksa dolum ekranını göster; varsa arka
  /// planda aç/güncelle ve akışa hemen devam et.
  Future<void> _checkData() async {
    // HERHANGİ bir şehrin paketi var mı? Hiçbiri yoksa veri paketi ekranı
    // gösterilir; oradaki indirme tamamen kullanıcının seçimidir.
    var has = false;
    for (final c in TransitCities.all) {
      if (await BusDataService.instance.hasLocal(c)) {
        has = true;
        break;
      }
    }
    if (!mounted) return;
    setState(() => _dataReady = has);
    // Aktif şehrin veritabanını arka planda aç — akışı bekletmeden.
    if (has) unawaited(_openActiveCity());
  }

  Future<void> _openActiveCity() async {
    try {
      final city = await ref.read(cityProvider.future);
      await BusDataService.instance.ensureReady(city: city);
      // ÖTEKİ kurulu şehirleri de aç. Arama ve yakındaki duraklar aktif
      // şehirle sınırlı değil: ayarı İstanbul'da kalmış bir kullanıcı
      // Kocaeli'ye gittiğinde çevresini görebilmeli.
      await BusDataService.instance.openAllForLookup();
    } catch (_) {
      // Paket yoksa/açılamazsa ray-vapur ile devam edilir.
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
    var justBecameReady = false;
    setState(() {
      final current = _permissionsOk;
      if (current == null) {
        // İlk açılış: izinler tamsa kapıyı hiç gösterme.
        _permissionsOk = report.criticalGranted;
        justBecameReady = report.criticalGranted;
      } else if (current && !report.criticalGranted) {
        // Kullanımdayken izin geri alındı: kapı yeniden öne gelsin.
        _permissionsOk = false;
      }
      // Kapı görünürken (false) otomatik true'ya ÇEKME: ayarlardan her
      // dönüşte sayfanın aniden kapanıp kullanıcıyı yarıda bırakmaması için
      // kapı yalnızca kendi "Devam et" butonuyla (onCompleted) kapanır.
    });
    // İzinler zaten verilmişse dolum akışı burada başlar (kapı gösterilmedi).
    if (justBecameReady && _dataReady == null) await _checkData();
  }

  @override
  Widget build(BuildContext context) {
    // RIZA HER ŞEYDEN ÖNCE. Konum izni istemeden, hesap açmadan ve reklam
    // göstermeden önce kullanıcı verisinin nasıl işlendiğini kabul etmiş
    // olmalı; mağazaların veri güvenliği beyanları da bunu gerektiriyor.
    final consent = ref.watch(consentProvider);
    if (consent.valueOrNull == false) {
      return ConsentScreen(onAccepted: () {
        if (mounted) setState(() {});
      });
    }
    if (consent.valueOrNull == null) return const _Splash();

    final onboarding = ref.watch(onboardingProvider);
    return onboarding.when(
      loading: () => const _Splash(),
      error: (_, __) => const BottomNavShell(),
      data: (done) {
        if (!done) return const OnboardingScreen();

        // SIRA ÖNEMLİ: önce İZİN, sonra VERİ PAKETİ.
        //
        // Tersi olduğunda uygulamayı ilk açan kişi hiçbir açıklama görmeden
        // sistem konum penceresiyle karşılaşıyordu (şehir tahmini konum
        // istiyor). Artık izin, gerekçesini anlatan "Başlamadan Önce"
        // ekranında isteniyor; şehir ondan sonra konumdan belirleniyor ve
        // doğru şehrin paketi iniyor.
        final permissionsOk = _permissionsOk;
        if (permissionsOk == null) return const _Splash();
        if (!permissionsOk) {
          return PermissionGateScreen(
            onCompleted: () {
              if (!mounted) return;
              setState(() => _permissionsOk = true);
              // İzin verildi: şehri şimdi konumdan belirle, paketi ona göre in.
              unawaited(_afterPermissions());
            },
          );
        }

        final dataReady = _dataReady;
        if (dataReady == null) return const _Splash();
        if (!dataReady) {
          return DataBootstrapScreen(
            onCompleted: () {
              if (!mounted) return;
              setState(() => _dataReady = true);
              unawaited(_openActiveCity());
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
