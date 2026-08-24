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
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            VigilantColors.primary.withValues(alpha: 0.18),
            VigilantColors.surfaceContainer,
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border:
            Border.all(color: VigilantColors.primary.withValues(alpha: 0.3)),
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
          const SizedBox(height: 6),
          Text(
            'Uygulamayı açmadan, ana ekranından yolculuğunu takip et: kalan '
            'durak ve mesafe widget’ta görünür, tek dokunuşla alarm kurarsın.',
            style: text.bodySmall?.copyWith(
                color: VigilantColors.onSurfaceVariant, height: 1.4),
          ),
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
