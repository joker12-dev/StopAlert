import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/haptics.dart';

/// Ağ gerektiren bir ekran veriyi getiremediğinde gösterilen kart.
///
/// NEDEN AYRI BİR PARÇA: bu ekranlar (duyurular, sefer saatleri, canlı konum)
/// veri gelmeyince bomboş kalıyordu. Kullanıcı ekranın bozuk mu olduğunu yoksa
/// gerçekten veri mi olmadığını anlayamıyordu — ikisi çok farklı şeyler ve
/// çözümleri de farklı.
///
/// "İnternet yok" demiyoruz: cihazın bağlantısı olup servisin cevap
/// vermediği durum da aynı görünüyor ve kullanıcıya yanlış yerde arattırmak
/// zaman kaybettirir. Söylediğimiz şey ölçtüğümüz şeydir: veri gelmedi.
class OfflineNotice extends StatelessWidget {
  const OfflineNotice({
    super.key,
    required this.title,
    this.detail,
    this.onRetry,
    this.compact = false,
  });

  /// Neyin getirilemediği ("Duyurular alınamadı").
  final String title;

  /// Ek açıklama — ekranın kendine özgü ipucu.
  final String? detail;

  final VoidCallback? onRetry;

  /// Panel içinde kullanılıyorsa daralt (tam ekran boşluk bırakma).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: 28, vertical: compact ? 18 : 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: compact ? 52 : 64,
              height: compact ? 52 : 64,
              decoration: BoxDecoration(
                color: VigilantColors.surfaceContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.wifi_off_rounded,
                  size: compact ? 24 : 30,
                  color: VigilantColors.onSurfaceVariant),
            ),
            SizedBox(height: compact ? 12 : 16),
            Text(title,
                textAlign: TextAlign.center,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              detail ??
                  'Bağlantını kontrol edip tekrar dene. Kurduğun alarmlar '
                      'internetsiz de çalışmaya devam eder.',
              textAlign: TextAlign.center,
              style: text.bodySmall
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
            if (onRetry != null) ...[
              SizedBox(height: compact ? 14 : 20),
              FilledButton.icon(
                onPressed: () {
                  Haptics.light();
                  onRetry!();
                },
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Tekrar dene'),
                style: FilledButton.styleFrom(
                  backgroundColor: VigilantColors.primary,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
