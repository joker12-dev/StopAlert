import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../services/ad_service.dart';
import '../util/platform_check.dart';

/// Gerçek AdMob banner reklamı yuvası.
///
/// - Yalnızca mobil cihazda (Android/iOS) yüklenir; web/masaüstü/testlerde
///   hiçbir şey çizmez (native reklam görünümü oluşturulmaz).
/// - Reklam yüklenene kadar yer kaplamaz (yükleyince görünür) — böylece
///   yükleme başarısız olursa ekranda boş bir kutu kalmaz.
class BannerAdSlot extends StatefulWidget {
  const BannerAdSlot({super.key});

  @override
  State<BannerAdSlot> createState() => _BannerAdSlotState();
}

class _BannerAdSlotState extends State<BannerAdSlot> {
  BannerAd? _ad;
  bool _loaded = false;
  bool _requested = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Ekran genişliği gerektiği için initState değil burada yükleriz; yalnızca
    // BİR KEZ istek atılır (her rebuild'de yeni istek = düşük eşleşme oranı).
    if (!isMobileDevice || _requested) return;
    _requested = true;
    _loadAdaptive();
  }

  /// UYARLANIR (anchored adaptive) banner: cihazın genişliğine göre boyut
  /// alır. Sabit 320x50'ye göre çok daha geniş reklam envanteri eşleşir —
  /// doldurma oranı ve eBGBM belirgin şekilde artar (AdMob önerisi).
  Future<void> _loadAdaptive() async {
    final width = MediaQuery.sizeOf(context).width.truncate();
    AdSize size;
    try {
      size = await AdSize.getLargeAnchoredAdaptiveBannerAdSize(width) ??
          AdSize.banner;
    } catch (_) {
      size = AdSize.banner;
    }
    if (!mounted) return;
    final ad = BannerAd(
      size: size,
      adUnitId: AdConfig.bannerUnitId,
      request: const AdRequest(),
      listener: BannerAdListener(
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
    return Container(
      alignment: Alignment.center,
      width: double.infinity,
      height: ad.size.height.toDouble(),
      child: SizedBox(
        width: ad.size.width.toDouble(),
        height: ad.size.height.toDouble(),
        child: AdWidget(ad: ad),
      ),
    );
  }
}
