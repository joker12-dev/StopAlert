import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../services/ad_service.dart';
import '../theme/app_theme.dart';
import '../util/platform_check.dart';
import 'ad_frame.dart';

/// YEREL (native advanced) reklam yuvası — liste içine gömülen reklam.
///
/// Banner'dan farkı, reklamın uygulamanın kendi kartlarına benzer bir düzende
/// çıkması: başlık, görsel, açıklama, buton. Doldurma oranı ve gelir banner'a
/// göre belirgin şekilde yüksek.
///
/// PLATFORM KODU GEREKTİRMEZ: eklentinin hazır şablonları ([TemplateType])
/// kullanılıyor. Kendi düzenimizi yazmak Android'de `NativeAdFactory`, iOS'ta
/// ayrı bir nib gerektirirdi; kazancı görsel, maliyeti iki platformda bakım.
///
/// Yüklenmezse HİÇ YER KAPLAMAZ — reklam gelmedi diye listede boşluk kalması
/// içeriğin kendisinden çalmak olurdu.
class NativeAdSlot extends StatefulWidget {
  const NativeAdSlot({
    super.key,
    this.template = TemplateType.medium,
    this.margin = const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
  });

  /// `small` dar listelerde (satır arası), `medium` sayfa sonlarında.
  final TemplateType template;
  final EdgeInsets margin;

  @override
  State<NativeAdSlot> createState() => _NativeAdSlotState();
}

class _NativeAdSlotState extends State<NativeAdSlot> {
  NativeAd? _ad;
  bool _loaded = false;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    if (!isMobileDevice || _requested) return;
    _requested = true;
    _load();
  }

  void _load() {
    final ad = NativeAd(
      adUnitId: AdConfig.nativeUnitId,
      request: const AdRequest(),
      nativeTemplateStyle: NativeTemplateStyle(
        templateType: widget.template,
        // Uygulamanın koyu temasına oturt: sistem varsayılanı beyaz bir kart
        // çiziyor ve karanlık ekranda göz alıyordu.
        mainBackgroundColor: VigilantColors.surfaceContainerLow,
        cornerRadius: 12,
        callToActionTextStyle: NativeTemplateTextStyle(
          textColor: Colors.white,
          backgroundColor: VigilantColors.primary,
          size: 14,
        ),
        primaryTextStyle: NativeTemplateTextStyle(
          textColor: Colors.white,
          backgroundColor: VigilantColors.surfaceContainerLow,
          size: 15,
        ),
        secondaryTextStyle: NativeTemplateTextStyle(
          textColor: VigilantColors.onSurfaceVariant,
          backgroundColor: VigilantColors.surfaceContainerLow,
          size: 13,
        ),
        tertiaryTextStyle: NativeTemplateTextStyle(
          textColor: VigilantColors.onSurfaceVariant,
          backgroundColor: VigilantColors.surfaceContainerLow,
          size: 12,
        ),
      ),
      listener: NativeAdListener(
        onAdLoaded: (_) {
          if (mounted) setState(() => _loaded = true);
        },
        onAdFailedToLoad: (ad, _) => ad.dispose(),
      ),
    );
    _ad = ad;
    ad.load();
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ad = _ad;
    if (ad == null || !_loaded) return const SizedBox.shrink();
    // Şablonun kendi yüksekliği var; AdWidget sınırsız yükseklikte çizilemiyor.
    final height = switch (widget.template) {
      TemplateType.small => 100.0,
      TemplateType.medium => 320.0,
    };
    return AdFrame(
      loaded: true,
      margin: widget.margin,
      child: SizedBox(height: height, child: AdWidget(ad: ad)),
    );
  }
}
