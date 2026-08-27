import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/home_tour_provider.dart';
import '../state/tour_keys.dart';
import '../theme/app_theme.dart';
import '../util/anim_config.dart';
import '../util/haptics.dart';

/// Ana sayfaya ilk gelişte tanıtım turunu (bir kez) başlatan görünmez tetikçi.
///
/// Ana sayfanın Stack'ine konur; kendisi hiçbir şey çizmez. Tur [Overlay]
/// üzerinden (alt menü dâhil her şeyin üstünde) açılır. Testlerde ([AppAnim]
/// kapalı) hiç çalışmaz — aksi hâlde katman dokunuşları emer ve testler kırılır.
class HomeTourTrigger extends ConsumerStatefulWidget {
  const HomeTourTrigger({super.key});

  @override
  ConsumerState<HomeTourTrigger> createState() => _HomeTourTriggerState();
}

class _HomeTourTriggerState extends ConsumerState<HomeTourTrigger> {
  bool _launched = false;
  OverlayEntry? _entry;

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  void _launch() {
    if (_launched) return;
    _launched = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final overlay = Overlay.of(context, rootOverlay: true);
      late OverlayEntry entry;
      entry = OverlayEntry(
        builder: (_) => _TourOverlay(onFinish: () {
          entry.remove();
          if (_entry == entry) _entry = null;
          ref.read(homeTourSeenProvider.notifier).markDone();
        }),
      );
      _entry = entry;
      overlay.insert(entry);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Testlerde ve animasyon kapalıyken tur açılmaz.
    if (!AppAnim.enabled) return const SizedBox.shrink();
    final seen = ref.watch(homeTourSeenProvider).valueOrNull;
    if (seen == false) _launch();
    return const SizedBox.shrink();
  }
}

class _TourStep {
  const _TourStep({required this.key, required this.title, required this.body});
  final GlobalKey key;
  final String title;
  final String body;
}

/// Turun kendisi — hedefe spotlight, kalan ekran bulanık+karanlık; balonda
/// açıklama + Önceki/Sıradaki; altta nokta göstergesi; sağ üstte Atla.
class _TourOverlay extends StatefulWidget {
  const _TourOverlay({required this.onFinish});
  final VoidCallback onFinish;

  @override
  State<_TourOverlay> createState() => _TourOverlayState();
}

class _TourOverlayState extends State<_TourOverlay> {
  int _i = 0;

  static final _steps = <_TourStep>[
    _TourStep(
      key: TourKeys.search,
      title: 'Ara',
      body: 'İneceğin durağı ya da binmek istediğin hattı buradan arayabilirsin.',
    ),
    _TourStep(
      key: TourKeys.alarm,
      title: 'Alarm Başlat',
      body: 'En yakın durağa göre inme alarmını buradan kurarsın; '
          'durağına yaklaşınca seni uyandırır.',
    ),
    _TourStep(
      key: TourKeys.categories,
      title: 'Ulaşım türleri',
      body: 'Otobüs, metrobüs, Marmaray, metro ve vapur hatlarını türüne '
          'göre buradan bulursun.',
    ),
    _TourStep(
      key: TourKeys.bell,
      title: 'Duyurular',
      body: 'Uygulamayla ilgili bakım, güncelleme ve bilgilendirmeleri '
          'buradan görürsün.',
    ),
    _TourStep(
      key: TourKeys.nav,
      title: 'Menü',
      body: 'Ana Sayfa, Hatlar, Duraklar, Favoriler ve Profil arasında '
          'buradan geçersin.',
    ),
  ];

  Rect? _rectFor(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _next() {
    Haptics.selection();
    if (_i < _steps.length - 1) {
      setState(() => _i++);
    } else {
      widget.onFinish();
    }
  }

  void _prev() {
    if (_i == 0) return;
    Haptics.selection();
    setState(() => _i--);
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final text = Theme.of(context).textTheme;
    final step = _steps[_i];
    final raw = _rectFor(step.key);
    // Hedefin çevresine küçük bir pay bırak.
    final hole = raw?.inflate(6);
    final last = _i == _steps.length - 1;

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // 1) Tüm dokunuşları emen taban (delik dâhil — gerçek butona
          //    yanlışlıkla basılmasın).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
            ),
          ),
          // 2) Bulanık + karanlık perde; hedefin olduğu yerde DELİK.
          Positioned.fill(
            child: IgnorePointer(
              child: _Scrim(hole: hole),
            ),
          ),
          // 3) Deliğin çevresine ince marka rengi halka.
          if (hole != null)
            Positioned(
              left: hole.left,
              top: hole.top,
              width: hole.width,
              height: hole.height,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: VigilantColors.primary, width: 2),
                  ),
                ),
              ),
            ),
          // 4) Sağ üstte "Atla".
          Positioned(
            top: safe.top + 4,
            right: 8,
            child: TextButton(
              onPressed: widget.onFinish,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                backgroundColor: Colors.white.withValues(alpha: 0.12),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999)),
              ),
              child: const Text('Atla'),
            ),
          ),
          // 5) Açıklama balonu.
          _bubble(size, hole, step, text, last),
          // 6) Nokta göstergesi — sayfanın altında.
          Positioned(
            left: 0,
            right: 0,
            bottom: safe.bottom + 22,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _steps.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _i ? 22 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: i == _i
                          ? VigilantColors.primary
                          : Colors.white.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(
      Size size, Rect? hole, _TourStep step, TextTheme text, bool last) {
    final card = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: VigilantColors.primary.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 24,
              offset: const Offset(0, 10)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(step.title,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(step.body,
              style: text.bodyMedium?.copyWith(
                  color: VigilantColors.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: 16),
          Row(
            children: [
              // Adım sayacı.
              Text('${_i + 1}/${_steps.length}',
                  style: text.labelMedium
                      ?.copyWith(color: VigilantColors.onSurfaceVariant)),
              const Spacer(),
              if (_i > 0)
                TextButton.icon(
                  onPressed: _prev,
                  icon: const Icon(Icons.chevron_left, size: 18),
                  label: const Text('Önceki'),
                  style: TextButton.styleFrom(
                      foregroundColor: VigilantColors.onSurfaceVariant),
                ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: _next,
                style: FilledButton.styleFrom(
                  backgroundColor: VigilantColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(last ? 'Bitir' : 'Sıradaki'),
              ),
            ],
          ),
        ],
      ),
    );

    const margin = 16.0;
    if (hole == null) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(margin), child: card),
      );
    }
    // Hedef üst yarıdaysa balon ALTINA, alt yarıdaysa ÜSTÜNE.
    final below = hole.center.dy < size.height / 2;
    if (below) {
      return Positioned(
          left: margin, right: margin, top: hole.bottom + 14, child: card);
    }
    return Positioned(
        left: margin,
        right: margin,
        bottom: size.height - hole.top + 14,
        child: card);
  }
}

/// Bulanık + karanlık perde; [hole] verilirse orada delik açar (o bölge net
/// kalır, spotlight etkisi). ClipPath + evenOdd ile blur yalnızca delik DIŞINA
/// uygulanır.
class _Scrim extends StatelessWidget {
  const _Scrim({required this.hole});
  final Rect? hole;

  @override
  Widget build(BuildContext context) {
    final blurred = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
      child: Container(color: Colors.black.withValues(alpha: 0.62)),
    );
    final h = hole;
    if (h == null) return blurred;
    return ClipPath(clipper: _HoleClipper(h), child: blurred);
  }
}

class _HoleClipper extends CustomClipper<Path> {
  _HoleClipper(this.hole);
  final Rect hole;

  @override
  Path getClip(Size size) => Path()
    ..addRect(Offset.zero & size)
    ..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(14)))
    ..fillType = PathFillType.evenOdd;

  @override
  bool shouldReclip(_HoleClipper old) => old.hole != hole;
}
