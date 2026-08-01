import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/insets.dart';
import 'privacy_screen.dart';

/// Yardım Merkezi — sık sorulanlar + güvenilirlik ipuçları (özellikle "alarm
/// çalmadı" için OEM/pil ayarları).
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const _faq = <(String, String)>[
    (
      'Alarm nasıl çalışır?',
      'İnmek istediğin durağa seçtiğin eşik kadar (ör. 500 m ya da 2 durak) '
          'yaklaşınca StopAlert tam ekran alarm çalar; telefon kilitliyse ekran '
          'kendiliğinden yanar. Alarmı kaydırarak durdurursun; takip, gerçekten '
          'varana kadar sürer.'
    ),
    (
      'İzinler neden gerekli?',
      'Arka planda konum ("Her zaman izin ver") olmadan uygulamadan çıkınca '
          'takip durur. Tam ekran alarm izni olmadan alarm, ekran kapalıyken '
          'sessiz kalabilir. İkisini de vermen önerilir.'
    ),
    (
      'Metroda / tünelde (GPS yokken) çalışır mı?',
      'Evet. GPS kaybında StopAlert; geçen süreyi, ivmeölçerle durak duruşlarını '
          've ÖĞRENDİĞİ gerçek durak sürelerini birleştirerek tahmini takip '
          'yapar ("Sinyal yok" modu). Sinyal geri gelince konum otomatik '
          'düzeltilir.'
    ),
    (
      'Alarm çalmadı — ne yapmalıyım?',
      'Genelde sebebi telefonun pil/OEM kısıtlamalarıdır:\n'
          '• Ayarlar → Pil → StopAlert için "Kısıtlama yok / Arka planda çalış".\n'
          '• Xiaomi/Oppo/Vivo/Samsung: "Otomatik başlat" + "Arka planda açılır '
          'pencere / uygulama üzerinde göster" izinlerini aç.\n'
          '• Alarm ses düzeyini yükselt (alarm kanalından çalar).\n'
          'StopAlert ayrıca ağdan bağımsız bir yedek (emniyet kemeri) alarm '
          'zamanlayıcısı çalıştırır.'
    ),
    (
      'Ses ve titreşimi nasıl değiştiririm?',
      'Ayarlar → Bildirimler bölümünden titreşimi açıp kapatabilir, erteleme '
          'süresini ve varsayılan alarm eşiğini seçebilirsin.'
    ),
    (
      'Verilerim güvende mi?',
      'Konumun yalnızca aktif yolculukta ve cihazında işlenir; sunucuya konum '
          'izi gönderilmez. Öğrenilen süreler cihazında kalır. Dilediğin an '
          'Ayarlar → Verilerimi Sil ile hepsini kaldırabilirsin.'
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
        title: const Text('Yardım Merkezi'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 8, 20, AppInsets.pageBottom(context) + 16),
        children: [
          for (final (q, a) in _faq) ...[
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(
                color: VigilantColors.surfaceContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  iconColor: VigilantColors.primary,
                  collapsedIconColor: VigilantColors.onSurfaceVariant,
                  title: Text(q,
                      style:
                          text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      a,
                      style: text.bodyMedium?.copyWith(
                        color: VigilantColors.onSurfaceVariant,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PrivacyScreen()),
              ),
              icon: const Icon(Icons.privacy_tip_outlined, size: 18),
              label: const Text('Gizlilik & KVKK'),
            ),
          ),
        ],
      ),
    );
  }
}
