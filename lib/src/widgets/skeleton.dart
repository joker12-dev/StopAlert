import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/anim_config.dart';

/// İskelet (shimmer) yer tutucu — içerik yüklenirken gösterilir.
///
/// Sürekli kayan parıltı [AppAnim.enabled] ile denetlenir: testlerde kapalıyken
/// statik bir kutu çizer, `pumpAndSettle`'ı kilitlemez.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 16,
    this.radius = 8,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
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
    const base = VigilantColors.surfaceContainerHigh;
    const highlight = VigilantColors.surfaceContainerHighest;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value;
        final begin = Alignment(-1.0 - 2 * (1 - t), 0);
        final end = Alignment(1.0 + 2 * t, 0);
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: AppAnim.enabled
                ? LinearGradient(
                    begin: begin,
                    end: end,
                    colors: const [base, highlight, base],
                  )
                : null,
            color: AppAnim.enabled ? null : base,
          ),
        );
      },
    );
  }
}

/// Yuvarlak köşeli kart görünümlü iskelet satırı (liste öğeleri için).
class SkeletonTile extends StatelessWidget {
  const SkeletonTile({super.key, this.height = 76});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          const SkeletonBox(width: 44, height: 44, radius: 14),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                SkeletonBox(width: 150, height: 14),
                SizedBox(height: 8),
                SkeletonBox(width: 90, height: 12),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
