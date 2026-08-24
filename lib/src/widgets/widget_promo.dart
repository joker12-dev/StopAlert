import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/home_widget_service.dart';
import '../state/widget_promo_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/platform_check.dart';

/// "Ana ekrana widget ekle" akışını başlatır.
///
/// Sistem sabitleme penceresini destekliyorsa doğrudan açar (tek dokunuş).
/// Desteklemiyorsa (bazı OEM başlatıcılar) elle ekleme yönergesini gösterir —
/// sessizce hiçbir şey yapmamak "bozuk" hissi verirdi.
Future<void> promptAddWidget(BuildContext context) async {
  Haptics.light();
  if (await HomeWidgetService.isPinSupported()) {
    await HomeWidgetService.requestPin();
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ManualAddSheet(),
  );
}

/// Ana sayfadaki tek-seferlik widget tanıtım kartı.
///
/// Yalnızca Android'de ve kart kapatılmadıysa görünür. Kapatınca ya da
/// "Ana ekrana ekle"ye basınca bir daha çıkmaz (bkz. widgetPromoDismissed).
class WidgetPromoCard extends ConsumerWidget {
  const WidgetPromoCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isAndroidDevice) return const SizedBox.shrink();
    final dismissed =
        ref.watch(widgetPromoDismissedProvider).valueOrNull ?? true;
    if (dismissed) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 14),
      decoration: BoxDecoration(
        // KOYU zemin: kart daha sakin dursun, önizleme öne çıksın.
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.widgets_rounded,
                  size: 20, color: VigilantColors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Ana ekran widget’ı',
                    style: text.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w800)),
              ),
              InkResponse(
                onTap: () {
                  Haptics.light();
                  ref.read(widgetPromoDismissedProvider.notifier).dismiss();
                },
                radius: 18,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close_rounded,
                      size: 18, color: VigilantColors.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // ÖNİZLEME: widget'ın "alarm kurulu" hâli — açıklama yazısı yok,
          // maket zaten neye benzediğini gösteriyor.
          const _WidgetPreview(),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                ref.read(widgetPromoDismissedProvider.notifier).dismiss();
                promptAddWidget(context);
              },
              icon: const Icon(Icons.add_to_home_screen_rounded, size: 18),
              label: const Text('Ana ekrana ekle'),
              style: FilledButton.styleFrom(
                backgroundColor: VigilantColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sistem sabitleme penceresi yoksa gösterilen elle-ekleme yönergesi.
class _ManualAddSheet extends StatelessWidget {
  const _ManualAddSheet();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
        decoration: BoxDecoration(
          color: VigilantColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
              color: VigilantColors.surfaceVariant.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: VigilantColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('Widget’ı elle ekle',
                style: text.headlineSmall?.copyWith(fontSize: 20)),
            const SizedBox(height: 4),
            Text(
              'Telefonun bu adımı otomatik açamıyor; birkaç saniyede elle '
              'ekleyebilirsin:',
              style: text.bodySmall
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            const _Step(
                n: 1, text: 'Ana ekranda boş bir yere basılı tut.'),
            const _Step(n: 2, text: '“Widget’lar”a dokun.'),
            const _Step(
                n: 3,
                text: '“Stop Alert”i bul ve ana ekrana sürükle.'),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                style: FilledButton.styleFrom(
                  backgroundColor: VigilantColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                child: const Text('Anladım'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});

  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: VigilantColors.primary.withValues(alpha: 0.16),
              shape: BoxShape.circle,
            ),
            child: Text('$n',
                style: t.labelMedium?.copyWith(
                    color: VigilantColors.primary,
                    fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(text, style: t.bodyMedium?.copyWith(height: 1.35)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ana ekran widget'ının "alarm kurulu" hâlinin küçük ÖNİZLEMESİ.
///
/// Gerçek widget'ın düzenini taklit eder: solda kalan durak halkası, sağda
/// hat kodu + durum + hedef durak + mesafe. Örnek (statik) verilerle —
/// yalnızca "neye benziyor" sorusunu cevaplar.
class _WidgetPreview extends StatelessWidget {
  const _WidgetPreview();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        // Gerçek widget koyu bir zeminde duruyor.
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          // Kalan durak halkası.
          SizedBox(
            width: 58,
            height: 58,
            child: CustomPaint(
              painter: _MiniRing(),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('3',
                        style: text.titleLarge?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            height: 1)),
                    Text('durak',
                        style: text.labelSmall?.copyWith(
                            fontSize: 9,
                            color: Colors.white.withValues(alpha: 0.6))),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('34A',
                          style: text.labelSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800)),
                    ),
                    const SizedBox(width: 8),
                    Text('YAKLAŞIYOR',
                        style: text.labelSmall?.copyWith(
                            fontSize: 10,
                            color: VigilantColors.primary,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(height: 5),
                const Text('Kadıköy',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 1),
                Text('1,2 km · ~4 dk',
                    style: text.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.7))),
                const SizedBox(height: 5),
                Text('Şu an: Acıbadem · Sonraki: Ünalan',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelSmall?.copyWith(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.55))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Önizlemedeki kalan-durak halkası: gri iz + marka kırmızısı ilerleme yayı.
class _MiniRing extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 3;
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..color = Colors.white.withValues(alpha: 0.14);
    canvas.drawCircle(c, r, track);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..color = VigilantColors.primary;
    // Üstten başlayıp saat yönünde ~%68'lik yay (örnek ilerleme).
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -1.5708,
      6.2832 * 0.68,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(_MiniRing old) => false;
}
