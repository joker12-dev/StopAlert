import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/consent_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/legal_links.dart';

/// Kullanım koşulları + gizlilik/KVKK onayı — uygulamanın İLK ekranı.
///
/// NEDEN VAR: uygulama konum verisi işliyor, hesap açıyor ve reklam
/// gösteriyor. Bunların hepsi kullanıcının bilgisi ve rızasıyla olmalı;
/// mağazalar da (Google Play Veri Güvenliği, App Store Privacy) bunu
/// açıkça arıyor.
///
/// KISA TUTULDU. On paragraflık bir metni kimse okumuyor; okunmayan onay,
/// onay değildir. Burada ne topladığımız, ne yapmadığımız ve kullanıcının
/// neyi kontrol ettiği maddeler hâlinde duruyor. Uzun metinler ayarlardaki
/// bağlantılarda.
class ConsentScreen extends ConsumerStatefulWidget {
  const ConsentScreen({super.key, required this.onAccepted});

  final VoidCallback onAccepted;

  @override
  ConsumerState<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends ConsumerState<ConsentScreen> {
  bool _accepted = false;
  bool _busy = false;

  Future<void> _continue() async {
    if (!_accepted || _busy) return;
    setState(() => _busy = true);
    Haptics.light();
    await ref.read(consentProvider.notifier).accept();
    if (!mounted) return;
    widget.onAccepted();
  }

  /// Metne giden tıklanabilir bağlantı parçası.
  TextSpan _linkSpan(BuildContext context, String label, String url) => TextSpan(
        text: label,
        style: const TextStyle(
          color: VigilantColors.primary,
          decoration: TextDecoration.underline,
          decorationColor: VigilantColors.primary,
          fontWeight: FontWeight.w700,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () => LegalLinks.open(context, url),
      );

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: VigilantColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
                children: [
                  Center(
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: VigilantColors.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(24),
                      ),
                      child: const Icon(Icons.shield_outlined,
                          size: 38, color: VigilantColors.primary),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('Başlamadan önce',
                      textAlign: TextAlign.center,
                      style: text.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    'StopAlert’i kullanabilmen için verilerini nasıl '
                    'işlediğimizi bilmen gerekiyor.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  const _ConsentRow(
                    icon: Icons.my_location_rounded,
                    title: 'Konumun yalnızca alarm için',
                    detail: 'Durağa yaklaştığını anlamak için konumun '
                        'kullanılır. Yolculuk sürerken arka planda da okunur; '
                        'alarm kurulu değilken okunmaz.',
                  ),
                  const SizedBox(height: 12),
                  const _ConsentRow(
                    icon: Icons.phone_android_rounded,
                    title: 'Rotan cihazında kalır',
                    detail: 'Nereden nereye gittiğin cihazında tutulur. '
                        'Hesap açarsan favorilerin ve geçmişin hesabınla '
                        'birlikte buluta yedeklenir.',
                  ),
                  const SizedBox(height: 12),
                  const _ConsentRow(
                    icon: Icons.insights_rounded,
                    title: 'Katkı senin seçimin',
                    detail: 'Duraklar arası geçen süreleri anonim olarak '
                        'paylaşıp tahminleri herkes için iyileştirebilirsin. '
                        'Varsayılan KAPALI; Ayarlar’dan açarsın.',
                  ),
                  const SizedBox(height: 12),
                  const _ConsentRow(
                    icon: Icons.campaign_outlined,
                    title: 'Reklam',
                    detail: 'Uygulama ücretsiz kalsın diye bazı sayfalarda '
                        'reklam gösterilir. Reklamlar "REKLAM" etiketiyle '
                        'işaretlidir.',
                  ),
                  const SizedBox(height: 20),
                  // Onay kutusu METNİN ALTINDA: üstte olsaydı kimse
                  // maddeleri okumadan geçerdi.
                  InkWell(
                    onTap: () {
                      Haptics.selection();
                      setState(() => _accepted = !_accepted);
                    },
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Checkbox(
                            value: _accepted,
                            onChanged: (v) {
                              Haptics.selection();
                              setState(() => _accepted = v ?? false);
                            },
                            activeColor: VigilantColors.primary,
                            side: const BorderSide(
                                color: VigilantColors.onSurfaceVariant),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 12),
                              // METİNLER OKUNABİLİR OLMALI: "okudum" diyen bir
                              // onayın yanında metne gidecek bir yol yoksa o
                              // onay geçerli sayılmaz.
                              child: Text.rich(
                                TextSpan(
                                  style: text.bodySmall?.copyWith(height: 1.4),
                                  children: [
                                    _linkSpan(context, 'Kullanım Koşulları',
                                        LegalLinks.terms),
                                    const TextSpan(text: '’nı ve '),
                                    _linkSpan(
                                        context,
                                        'Gizlilik/KVKK Aydınlatma Metni',
                                        LegalLinks.privacy),
                                    const TextSpan(
                                        text: '’ni okudum, kabul ediyorum.'),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: VigilantColors.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: VigilantColors.surfaceVariant,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  // KABUL ETMEDEN GEÇİLMEZ. "Sonra sorarız" demek, rızayı
                  // alınmış saymak olurdu.
                  onPressed: _accepted && !_busy ? _continue : null,
                  child: Text(_accepted
                      ? 'Kabul et ve başla'
                      : 'Devam etmek için kabul et'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rıza ekranındaki tek madde.
class _ConsentRow extends StatelessWidget {
  const _ConsentRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: VigilantColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: text.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(detail,
                    style: text.labelMedium?.copyWith(
                        color: VigilantColors.onSurfaceVariant, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
