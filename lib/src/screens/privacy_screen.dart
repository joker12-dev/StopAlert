import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Gizlilik & KVKK — hangi verinin toplandığını, nasıl kullanıldığını ve
/// kullanıcının haklarını (silme dahil) açıklar.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  static const _sections = <(String, String)>[
    (
      'Kısaca',
      'StopAlert, ineceğin durağı kaçırmaman için konumunu YALNIZCA aktif '
          'yolculuk sırasında ve cihazında işler. Konum geçmişin sunucuya '
          'gönderilmez.'
    ),
    (
      'Toplanan veriler',
      '• Anonim oturum kimliği (Firebase; adın/e-postan istenmez).\n'
          '• Tamamladığın yolculukların özeti (hat, biniş/iniş durağı, süre, '
          'tarih) — hesabına özel, yalnızca sana görünür.\n'
          '• Kaydettiğin favori rotalar.'
    ),
    (
      'Konum',
      'Konum, yalnızca alarm kurulu bir yolculuk sürerken kullanılır ve '
          'durağa yaklaştığını hesaplamak için işlenir. Ham konum izi buluta '
          'yazılmaz; yolculuk bitince takip durur.'
    ),
    (
      'Cihazda öğrenme',
      'Uygulama, tahminini iyileştirmek için duraklar arası gerçek süreleri '
          'ÖĞRENİR. Bu öğrenilen veriler CİHAZINDA kalır. İleride yalnızca '
          'açık rızanla, kimliğinden arındırılmış biçimde toplu iyileştirmeye '
          'katkı seçeneği sunulabilir.'
    ),
    (
      'Haklarısın (KVKK)',
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
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
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
          Text(
            'Bu metin ürün geliştikçe güncellenecektir.',
            style: text.labelMedium
                ?.copyWith(color: VigilantColors.outlineVariant),
          ),
        ],
      ),
    );
  }
}
