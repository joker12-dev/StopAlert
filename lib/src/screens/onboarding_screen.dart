import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/location_service.dart';
import '../state/onboarding_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/mascot.dart';

/// İlk açılış tanıtımı + izin hazırlığı.
///
/// Üç değer slaytı ve bir izin adımı. İzin adımında konum izni istenir
/// (alarmın çalışabilmesi için kritik); bildirim izni ise native derlemede
/// eklenecek. Tamamlanınca [onboardingProvider] işaretlenir ve kök widget
/// otomatik olarak ana ekrana geçer.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;
  bool _requesting = false;

  static const _slides = [
    _SlideData(
      mascot: MascotAssets.merhaba,
      color: VigilantColors.primary,
      title: 'Durağını asla kaçırma',
      body: 'Marmaray, metro, tramvay ve vapurda yolculuğunu takip eder; '
          'ineceğin durak yaklaşınca seni uyarır.',
    ),
    _SlideData(
      mascot: MascotAssets.yaklasiyoruz,
      color: VigilantColors.tertiaryContainer,
      title: 'Yer altında bile çalışır',
      body: 'GPS çekmeyen tünel ve metrolarda zaman sayacı ve hareket '
          'sensörüyle takibe devam eder.',
    ),
    _SlideData(
      mascot: MascotAssets.uyuyor,
      color: VigilantColors.secondary,
      title: 'Tam zamanında uyandırır',
      body: 'Telefon cebinde, ekran kapalı ya da uyuyor olsan bile güçlü '
          'alarm ile seni haberdar eder.',
    ),
  ];

  bool get _isLastPage => _page == _slides.length; // izin sayfası en sonda

  Future<void> _finish() async {
    setState(() => _requesting = true);
    // Konum iznini iste (tarayıcı/işletim sistemi izin penceresini açar).
    await LocationService().currentLocation();
    await ref.read(onboardingProvider.notifier).complete();
    // Kök widget onboardingProvider'ı izlediği için ana ekrana kendisi geçer.
  }

  void _next() {
    _controller.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Atla
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: TextButton(
                  onPressed: _requesting
                      ? null
                      : () => ref.read(onboardingProvider.notifier).complete(),
                  child: Text(
                    'Atla',
                    style: text.labelLarge
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  for (final s in _slides) _Slide(data: s),
                  _PermissionPage(requesting: _requesting),
                ],
              ),
            ),
            // Nokta göstergeleri
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _slides.length + 1; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _page ? 24 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _page
                          ? VigilantColors.primary
                          : VigilantColors.outlineVariant,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            // Alt buton
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: SizedBox(
                height: 56,
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: VigilantColors.primary,
                    foregroundColor: VigilantColors.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: text.labelLarge,
                  ),
                  onPressed:
                      _requesting ? null : (_isLastPage ? _finish : _next),
                  child: _requesting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: VigilantColors.onPrimary,
                          ),
                        )
                      : Text(_isLastPage ? 'Konum izni ver ve başla' : 'İleri'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlideData {
  const _SlideData({
    required this.mascot,
    required this.color,
    required this.title,
    required this.body,
  });

  /// Slaytın STOPİ pozu (assets/mascot).
  final String mascot;
  final Color color;
  final String title;
  final String body;
}

class _Slide extends StatelessWidget {
  const _Slide({required this.data});

  final _SlideData data;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // STOPİ: slaytın pozu, arkasında yumuşak renk ışıması.
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: data.color.withValues(alpha: 0.22),
                  blurRadius: 70,
                  spreadRadius: 12,
                ),
              ],
            ),
            child: Mascot(data.mascot, height: 190),
          ),
          const SizedBox(height: 36),
          Text(
            data.title,
            textAlign: TextAlign.center,
            style: text.headlineMedium,
          ),
          const SizedBox(height: 12),
          Text(
            data.body,
            textAlign: TextAlign.center,
            style: text.bodyLarge
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _PermissionPage extends StatelessWidget {
  const _PermissionPage({required this.requesting});

  final bool requesting;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // STOPİ tanıtım pozu (telefonlu) — izin adımının elçisi.
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: VigilantColors.primary.withValues(alpha: 0.2),
                  blurRadius: 70,
                  spreadRadius: 12,
                ),
              ],
            ),
            child: const Mascot(MascotAssets.hero, height: 170),
          ),
          const SizedBox(height: 24),
          Text(
            'Başlamadan önce',
            textAlign: TextAlign.center,
            style: text.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'StopAlert’ın seni doğru durakta uyandırabilmesi için birkaç izne '
            'ihtiyacı var.',
            textAlign: TextAlign.center,
            style: text.bodyLarge
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
          const SizedBox(height: 28),
          const _PermItem(
            icon: Icons.my_location,
            color: VigilantColors.primary,
            title: 'Konum',
            body: 'Yolculuğunu takip edip durağın yaklaşınca uyarmak için.',
          ),
          const SizedBox(height: 14),
          const _PermItem(
            icon: Icons.notifications_active_outlined,
            color: VigilantColors.secondary,
            title: 'Bildirim ve alarm',
            body: 'Ekran kapalıyken bile seni uyandırabilmek için. '
                '(Uygulama içinde istenecek.)',
          ),
        ],
      ),
    );
  }
}

class _PermItem extends StatelessWidget {
  const _PermItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.15),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style:
                        text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: text.bodySmall
                      ?.copyWith(color: VigilantColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
