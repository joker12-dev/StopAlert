import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../util/anim_config.dart';

/// STOPİ — StopAlert maskotunun pozları (assets/mascot, şeffaf PNG).
///
/// sprite_* dosyaları tasarımcıdan geldiği gibi; uyuyor/yaklasiyoruz,
/// sprite_006'dan türetilmiş iki yarımdır; logo.png köşeleri temizlenmiş
/// uygulama logosudur (tool: scratchpad/prep_assets.py).
abstract final class MascotAssets {
  static const hero = 'assets/mascot/sprite_002.png';
  static const merhaba = 'assets/mascot/sprite_003.png';
  static const harika = 'assets/mascot/sprite_004.png';
  static const dikkat = 'assets/mascot/sprite_005.png';
  static const uyuyor = 'assets/mascot/uyuyor.png';
  static const yaklasiyoruz = 'assets/mascot/yaklasiyoruz.png';
  static const iyiYolculuklar = 'assets/mascot/sprite_007.png';

  // asset_paketi.png'den kesilen koyu zeminli "çıkartma" pozlar: kenarları
  // alpha ile eritilmiştir; koyu yüzeylerde dikişsiz durur (açık zeminde
  // kullanma). Kesici: scratchpad/crop_paket2.py
  static const poseMerhaba = 'assets/mascot/pose_merhaba.png';
  static const poseTelefon = 'assets/mascot/pose_telefon.png';
  static const poseMegafon = 'assets/mascot/pose_megafon.png';
  static const poseHarita = 'assets/mascot/pose_harita.png';
  static const poseUyandiran = 'assets/mascot/pose_uyandiran.png';
}

/// Ulaşım türü görselleri (kullanıcının araç renderları; beyaz zemin
/// şeffaflaştırıldı — kesici: scratchpad/cut_types.py).
abstract final class TypeAssets {
  static const otobus = 'assets/types/otobus.png';
  static const marmaray = 'assets/types/marmaray.png';
  static const metro = 'assets/types/metro.png';
  static const vapur = 'assets/types/vapur.png';
}

/// Tür temalı fotoğraf arkaplanları (asset_paketi.png'den kesildi).
abstract final class BannerAssets {
  static const marmaray = 'assets/banners/bg_marmaray.png';
  static const metro = 'assets/banners/bg_metro.png';
  static const tramvay = 'assets/banners/bg_tramvay.png';
  static const genel = 'assets/banners/bg_genel.png';
}

/// Maskotu tutarlı biçimde çizen küçük yardımcı (şeffaf PNG, contain).
class Mascot extends StatelessWidget {
  const Mascot(this.asset, {super.key, this.height = 140});

  final String asset;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      height: height,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }
}

/// Süzülen STOPİ — maskotu yumuşakça yukarı-aşağı süzdürür ve hafifçe eğer.
///
/// Sürekli tekrarlayan mikro animasyon [AppAnim.enabled] ile denetlenir:
/// testlerde kapalıyken sabit bir [Mascot] çizer (pumpAndSettle kilitlenmez).
class AnimatedMascot extends StatefulWidget {
  const AnimatedMascot(
    this.asset, {
    super.key,
    this.height = 140,
    this.amplitude = 7,
  });

  final String asset;
  final double height;

  /// Süzülme genliği (px).
  final double amplitude;

  @override
  State<AnimatedMascot> createState() => _AnimatedMascotState();
}

class _AnimatedMascotState extends State<AnimatedMascot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    // Controller'ı burada (mount'luyken) oluştur; dispose sırasında tembel
    // oluşturma TickerMode aramasını patlatır.
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
    if (AppAnim.enabled) _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mascot = Mascot(widget.asset, height: widget.height);
    if (!AppAnim.enabled) return mascot;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final phase = _c.value * 2 * math.pi;
        final dy = math.sin(phase) * widget.amplitude;
        final tilt = math.sin(phase) * 0.03; // hafif salınım
        return Transform.translate(
          offset: Offset(0, dy),
          child: Transform.rotate(angle: tilt, child: child),
        );
      },
      child: mascot,
    );
  }
}
