import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../util/legal_links.dart';

/// Gizlilik & KVKK — uygulama içi ÖZET.
///
/// Tam metin web'de (bkz. [LegalLinks]); mağazalar herkese açık bir URL
/// istiyor ve metin değişince yeni sürüm yayınlamamak için orada tutuluyor.
/// Bu ekran özeti gösterir ve tam metne bağlar; ikisi çelişmemeli, o yüzden
/// buradaki maddeler web'deki gizlilik.html ile aynı çerçevede yazıldı.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  static const _sections = <(String, String)>[
    (
      'Kısaca',
      'StopAlert, ineceğin durağı kaçırmaman için konumunu YALNIZCA aktif '
          'yolculuk sırasında ve cihazında işler. Nerede olduğun bize ya da '
          'başka bir sunucuya gönderilmez.'
    ),
    (
      'Konum',
      'Konum, yalnızca alarm kurulu bir yolculuk sürerken kullanılır ve '
          'durağa olan mesafeni hesaplamak için işlenir. Bu hesap cihazında '
          'yapılır. Alarm kurulu değilken konumun okunmaz; yolculuk bitince '
          'takip durur.'
    ),
    (
      'Cihazında kalanlar',
      '• Nereden nereye gittiğin (yolculuk geçmişi) cihazında tutulur.\n'
          '• Duraklar arası öğrenilen gerçek süreler cihazında kalır.\n'
          '• Ayarların ve son aramaların cihazında saklanır.'
    ),
    (
      'Hesap açarsan',
      'Google veya Apple ile giriş yaparsan favorilerin, geçmişin ve '
          'ayarların hesabına yedeklenir; ikinci telefonundan aynı hesapla '
          'girince geri gelir. Uygulama hesapsız da tam çalışır.'
    ),
    (
      'Reklam',
      'Uygulama ücretsiz kalsın diye bazı sayfalarda Google AdMob reklamları '
          'gösterilir. Reklam alanları "REKLAM" etiketiyle işaretlidir ve '
          'alarm akışını kesmez.'
    ),
    (
      'Katkı senin seçimin',
      'Duraklar arası süreleri ANONİM olarak paylaşıp tahminleri herkes için '
          'iyileştirebilirsin. Rotan, saatin ya da konumun gönderilmez; '
          'yalnızca kimliğe bağlanamayan toplam süreler. Varsayılan KAPALI.'
    ),
    (
      'Hakların (KVKK)',
      'Verilerini görebilir ve dilediğin an tümüyle silebilirsin: '
          'Ayarlar → "Verilerimi Sil". Silme; buluttaki yolculuk/favori '
          'kayıtlarını ve cihazdaki ayar/öğrenme verisini kaldırır.'
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('Gizlilik & KVKK'),
      ),
      body: ListView(
        padding:
            EdgeInsets.fromLTRB(20, 8, 20, AppInsets.pageBottom(context) + 16),
        children: [
          for (final (title, body) in _sections) ...[
            Text(title, style: text.headlineSmall?.copyWith(fontSize: 18)),
            const SizedBox(height: 8),
            Text(
              body,
              style: text.bodyMedium?.copyWith(
                color: VigilantColors.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
          ],
          // TAM METİN WEB'DE. Yukarısı özet; bağlayıcı metin bu iki sayfada.
          _LegalButton(
            icon: Icons.description_outlined,
            label: 'Gizlilik ve KVKK Aydınlatma Metni (tam)',
            onTap: () => LegalLinks.open(context, LegalLinks.privacy),
          ),
          const SizedBox(height: 10),
          _LegalButton(
            icon: Icons.gavel_rounded,
            label: 'Kullanım Koşulları',
            onTap: () => LegalLinks.open(context, LegalLinks.terms),
          ),
        ],
      ),
    );
  }
}

/// Yayındaki tam metne giden düğme.
class _LegalButton extends StatelessWidget {
  const _LegalButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 20, color: VigilantColors.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label,
                    style: text.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              const Icon(Icons.open_in_new_rounded,
                  size: 18, color: VigilantColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
