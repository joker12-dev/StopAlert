import 'package:flutter/material.dart';

import '../services/permission_service.dart';
import '../theme/app_theme.dart';
import '../util/platform_check.dart';
import '../widgets/mascot.dart';

/// İzin kapısı — arka plan takibi için zorunlu izinler tamamlanana kadar
/// uygulamanın önünde durur (yalnızca Android'de gösterilir).
///
/// Sıra: bildirim -> konum (kullanırken) -> "Her zaman izin ver" ->
/// pil optimizasyonu muafiyeti (önerilen). Kullanıcı ayarlardan dönünce
/// durum otomatik yeniden okunur (lifecycle resume).
///
/// Ekran KENDİLİĞİNDEN kapanmaz: tüm zorunlu izinler tamamlandığında
/// "Devam et" butonu aktifleşir ve [onCompleted] yalnızca bu butonla çağrılır.
/// (Ayarlardan dönüşte sayfanın aniden kapanıp kullanıcıyı yarım bırakması
/// bu yüzden bilinçli olarak engellenir.)
class PermissionGateScreen extends StatefulWidget {
  const PermissionGateScreen({super.key, required this.onCompleted});

  final VoidCallback onCompleted;

  @override
  State<PermissionGateScreen> createState() => _PermissionGateScreenState();
}

class _PermissionGateScreenState extends State<PermissionGateScreen>
    with WidgetsBindingObserver {
  final _service = PermissionService();
  PermissionStatusReport? _report;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Sistem ayarlarından dönüldüğünde durumu tazele.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final report = await _service.check();
    if (!mounted) return;
    setState(() => _report = report);
  }

  Future<void> _run(Future<bool> Function() request) async {
    if (_busy) return;
    setState(() => _busy = true);
    await request();
    if (mounted) setState(() => _busy = false);
    await _refresh();
  }

  /// Platforma göre izin adımları. iOS'ta yalnızca bildirim + konum (x2);
  /// tam ekran alarm / pil / overlay Android'e özeldir (iOS'ta yok).
  List<Widget> _buildSteps(PermissionStatusReport r) {
    final steps = <Widget>[];
    var i = 1;
    steps.add(_PermissionStep(
      index: i++,
      title: 'Bildirimler',
      subtitle: isAndroidDevice
          ? 'Takip bildirimi ve alarm için (Android 13+)'
          : 'Alarm ve yaklaşma uyarısı için',
      granted: r.notifications,
      onRequest: () => _run(_service.requestNotifications),
    ));
    if (isAndroidDevice) {
      steps.add(_PermissionStep(
        index: i++,
        title: 'Tam ekran alarm',
        subtitle:
            'Telefon kilitliyken alarm ekranını açmak için (Android 14+)',
        granted: r.fullScreenIntent,
        critical: true,
        onRequest: () => _run(_service.requestFullScreenIntent),
      ));
    }
    steps.add(_PermissionStep(
      index: i++,
      title: 'Konum (uygulamayı kullanırken)',
      subtitle: 'Yolculuğunu hat üzerinde takip etmek için',
      granted: r.locationWhenInUse,
      onRequest: () => _run(_service.requestWhenInUse),
    ));
    steps.add(_PermissionStep(
      index: i++,
      title: 'Konum: HER ZAMAN İZİN VER',
      subtitle: isAndroidDevice
          ? 'Ekran kapalıyken / uygulamadan çıkınca takip için şart. Açılan '
              'ayarda "Her zaman izin ver"i seç.'
          : 'Arka planda takip için şart. Açılan ayarda "Her Zaman"ı seç.',
      granted: r.locationAlways,
      enabled: r.locationWhenInUse,
      critical: true,
      onRequest: () => _run(_service.requestAlways),
    ));
    if (isAndroidDevice) {
      steps.add(_PermissionStep(
        index: i++,
        title: 'Pil optimizasyonu muafiyeti',
        subtitle: 'Telefonun uygulamayı arka planda öldürmemesi için önerilir '
            '(Xiaomi/Oppo/Samsung\'da önemli).',
        granted: r.batteryOptimizationExempt,
        optional: true,
        onRequest: () => _run(_service.requestBatteryExemption),
      ));
      steps.add(_PermissionStep(
        index: i++,
        title: 'Uygulama üzerinde göster',
        subtitle: 'Alarm ekranının arka plandan her koşulda açılabilmesi için '
            'önerilir. Xiaomi/Redmi\'de ayrıca: Diğer izinler > "Arka planda '
            'çalışırken açılır pencere göster"i aç.',
        granted: r.overlay,
        optional: true,
        onRequest: () => _run(_service.requestOverlay),
      ));
    }
    return steps;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = _report;
    return Scaffold(
      body: SafeArea(
        child: r == null
            ? const Center(
                child: CircularProgressIndicator(color: VigilantColors.primary),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                children: [
                  // STOPİ "Dikkat!" — izinlerin ciddiyetini sevimli anlatır.
                  const Center(child: Mascot(MascotAssets.dikkat, height: 132)),
                  const SizedBox(height: 16),
                  Text(
                    'Alarmın çalışması için izinler gerekli',
                    textAlign: TextAlign.center,
                    style: text.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'StopAlert, sen uygulamadan çıksan ya da telefon '
                    'kilitlense bile yolculuğunu takip edip seni uyandırır. '
                    'Bunun için aşağıdaki izinler şart:',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  ..._buildSteps(r),
                  const SizedBox(height: 20),
                  if (!r.criticalGranted)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: VigilantColors.tertiaryContainer
                            .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: VigilantColors.tertiaryContainer
                              .withValues(alpha: 0.4),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded,
                              color: VigilantColors.tertiaryContainer),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '"Her zaman izin ver" ve tam ekran alarm izni '
                              'olmadan arka plan takibi ÇALIŞMAZ.',
                              style: text.labelLarge?.copyWith(
                                  color: VigilantColors.tertiaryContainer),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: VigilantColors.secondary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color:
                              VigilantColors.secondary.withValues(alpha: 0.4),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.check_circle_outline,
                              color: VigilantColors.secondary),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Zorunlu izinler tamam — arka plan alarmı '
                              'kullanıma hazır.',
                              style: text.labelLarge
                                  ?.copyWith(color: VigilantColors.secondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 56,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: VigilantColors.primary,
                        foregroundColor: VigilantColors.onPrimary,
                        disabledBackgroundColor:
                            VigilantColors.surfaceContainer,
                        disabledForegroundColor: VigilantColors.outline,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                        textStyle: text.labelLarge
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      // Kapı YALNIZCA bu butonla kapanır; ayarlardan dönüşte
                      // otomatik kapanıp kullanıcıyı yarıda bırakmaz.
                      onPressed: r.criticalGranted ? widget.onCompleted : null,
                      child: Text(r.criticalGranted
                          ? 'Devam et'
                          : 'Devam etmek için zorunlu izinleri tamamla'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _service.openSettings,
                    icon: const Icon(Icons.settings_outlined,
                        size: 18, color: VigilantColors.onSurfaceVariant),
                    label: Text(
                      'İzin penceresi açılmıyorsa: uygulama ayarlarını aç',
                      style: text.labelMedium
                          ?.copyWith(color: VigilantColors.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _PermissionStep extends StatelessWidget {
  const _PermissionStep({
    required this.index,
    required this.title,
    required this.subtitle,
    required this.granted,
    required this.onRequest,
    this.enabled = true,
    this.critical = false,
    this.optional = false,
  });

  final int index;
  final String title;
  final String subtitle;
  final bool granted;
  final bool enabled;
  final bool critical;
  final bool optional;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final accent = granted
        ? VigilantColors.secondary
        : critical
            ? VigilantColors.tertiaryContainer
            : VigilantColors.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: granted
              ? VigilantColors.secondary.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.06),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.15),
            ),
            child: granted
                ? Icon(Icons.check, color: accent, size: 20)
                : Center(
                    child: Text('$index',
                        style: text.labelLarge?.copyWith(color: accent)),
                  ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  optional ? '$title (önerilen)' : title,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: text.labelMedium
                      ?.copyWith(color: VigilantColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (!granted)
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor:
                    enabled ? VigilantColors.primary : VigilantColors.outline,
                foregroundColor: VigilantColors.onPrimary,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: enabled ? onRequest : null,
              child: const Text('Ver'),
            ),
        ],
      ),
    );
  }
}
