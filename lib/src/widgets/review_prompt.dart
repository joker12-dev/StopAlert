import 'package:flutter/material.dart';

import '../services/app_review_service.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import 'mascot.dart';

/// "StopAlert işini gördü mü?" — ilk yolculuktan sonra bir kez çıkan istem.
///
/// Yıldız SORMUYOR: uygulama içinde toplanan yıldız mağazaya gitmez, kullanıcı
/// da iki kez puan vermiş olur. Burada yalnızca niyet sorulur; onay verilirse
/// mağazanın KENDİ puanlama penceresi açılır ([AppReviewService.request]).
Future<void> showReviewPrompt(BuildContext context) async {
  final choice = await showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (context) {
      final text = Theme.of(context).textTheme;
      return AlertDialog(
        backgroundColor: VigilantColors.surfaceContainer,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        contentPadding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Mascot(MascotAssets.harika, height: 96),
            const SizedBox(height: 16),
            Text(
              'Durağını kaçırmadın!',
              textAlign: TextAlign.center,
              style: text.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'İlk yolculuğun tamam. StopAlert işini gördüyse mağazada bir '
              'puan bırakır mısın? Yeni yolcuların bizi bulmasına yarıyor.',
              textAlign: TextAlign.center,
              style: text.bodyMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        actions: [
          Column(
            children: [
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: VigilantColors.primary,
                    foregroundColor: VigilantColors.onPrimary,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: () => Navigator.pop(context, 'rate'),
                  child: const Text('Puan ver'),
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.pop(context, 'later'),
                child: Text('Daha sonra',
                    style: text.labelLarge
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'never'),
                child: Text('Bir daha sorma',
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
              ),
            ],
          ),
        ],
      );
    },
  );

  switch (choice) {
    case 'rate':
      Haptics.light();
      await AppReviewService.request();
    case 'never':
      await AppReviewService.never();
    // 'later' ve kapatma: hiçbir şey yazılmaz, birkaç yolculuk sonra
    // yeniden sorulur (bkz. AppReviewService).
  }
}
