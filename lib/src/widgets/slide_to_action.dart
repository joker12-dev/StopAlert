import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../util/anim_config.dart';
import '../util/haptics.dart';

/// Kaydırarak onayla — "kaza ile durdurma"yı önleyen kaydırmalı aksiyon.
///
/// Tutamağı sağ uca kadar kaydırınca [onConfirmed] tetiklenir (uçta güçlü
/// haptik). Uca ulaşmadan bırakılırsa yumuşakça başa döner. Alarm ekranında
/// alarmı durdurmak ve canlı takipte yolculuğu bitirmek için kullanılır.
class SlideToAction extends StatefulWidget {
  const SlideToAction({
    super.key,
    required this.label,
    required this.onConfirmed,
    this.icon = Icons.chevron_right,
    this.trackColor,
    this.fillColor,
    this.thumbColor,
    this.foregroundColor,
    this.height = 64,
  });

  final String label;
  final VoidCallback onConfirmed;
  final IconData icon;
  final Color? trackColor;
  final Color? fillColor;
  final Color? thumbColor;
  final Color? foregroundColor;
  final double height;

  @override
  State<SlideToAction> createState() => _SlideToActionState();
}

class _SlideToActionState extends State<SlideToAction>
    with TickerProviderStateMixin {
  /// Tutamağın sol kenardan kayma miktarı (px).
  double _dx = 0;
  double _maxDx = 0;
  bool _confirmed = false;

  late final AnimationController _reset;
  Animation<double> _resetTween = const AlwaysStoppedAnimation(0);

  // Boştayken uca doğru akan ipucu parıltısı (sürekli — test dışında).
  late final AnimationController _hint;

  @override
  void initState() {
    super.initState();
    // Controller'ları mount'luyken oluştur (dispose'ta tembel oluşturma
    // TickerMode aramasını patlatır).
    _reset = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    )..addListener(() {
        setState(() => _dx = _resetTween.value);
      });
    _hint = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
    if (AppAnim.enabled) _hint.repeat();
  }

  @override
  void dispose() {
    _reset.dispose();
    _hint.dispose();
    super.dispose();
  }

  void _animateResetTo(double target) {
    _resetTween = Tween<double>(begin: _dx, end: target).animate(
      CurvedAnimation(parent: _reset, curve: Curves.easeOut),
    );
    _reset
      ..reset()
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final track = widget.trackColor ?? VigilantColors.surfaceContainerHighest;
    final fill = widget.fillColor ?? VigilantColors.primary;
    final thumb = widget.thumbColor ?? Colors.white;
    final fg = widget.foregroundColor ?? VigilantColors.onSurface;
    final thumbSize = widget.height - 8;

    return LayoutBuilder(
      builder: (context, constraints) {
        _maxDx = constraints.maxWidth - thumbSize - 8;
        if (_maxDx < 0) _maxDx = 0;
        final progress = _maxDx == 0 ? 0.0 : (_dx / _maxDx).clamp(0.0, 1.0);
        final hintShift = AppAnim.enabled ? _hint.value : 0.0;

        return AnimatedBuilder(
          animation: _hint,
          builder: (context, _) {
            return SizedBox(
              height: widget.height,
              child: Stack(
                children: [
                  // Zemin + dolan iz
                  Container(
                    decoration: BoxDecoration(
                      color: track,
                      borderRadius: BorderRadius.circular(widget.height),
                    ),
                  ),
                  Container(
                    width: (thumbSize + 8 + _dx).clamp(0.0, constraints.maxWidth),
                    decoration: BoxDecoration(
                      color: fill.withValues(alpha: 0.22 + progress * 0.5),
                      borderRadius: BorderRadius.circular(widget.height),
                    ),
                  ),
                  // Etiket (tutamak yaklaştıkça soluklaşır); tutamağın sağında
                  // durur ve taşmaması için esner.
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.only(left: thumbSize + 12, right: 14),
                      child: Center(
                        child: Opacity(
                          opacity: (1 - progress * 1.4).clamp(0.0, 1.0),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  widget.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: text.labelLarge?.copyWith(
                                    color: fg,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.3,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              // Akan çift ok ipucu
                              for (var i = 0; i < 3; i++)
                                Opacity(
                                  opacity: (((hintShift * 3) - i) % 3 < 1)
                                      ? 0.9
                                      : 0.3,
                                  child: Icon(Icons.keyboard_arrow_right,
                                      size: 18,
                                      color: fg.withValues(alpha: 0.8)),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Tutamak
                  Positioned(
                    left: 4 + _dx,
                    top: 4,
                    child: GestureDetector(
                      onHorizontalDragStart: (_) {
                        if (_confirmed) return;
                        Haptics.light();
                      },
                      onHorizontalDragUpdate: (d) {
                        if (_confirmed) return;
                        setState(() {
                          _dx = (_dx + d.delta.dx).clamp(0.0, _maxDx);
                        });
                      },
                      onHorizontalDragEnd: (_) {
                        if (_confirmed) return;
                        if (_dx >= _maxDx * 0.9) {
                          setState(() {
                            _dx = _maxDx;
                            _confirmed = true;
                          });
                          Haptics.heavy();
                          widget.onConfirmed();
                        } else {
                          _animateResetTo(0);
                        }
                      },
                      child: Container(
                        width: thumbSize,
                        height: thumbSize,
                        decoration: BoxDecoration(
                          color: thumb,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          _confirmed ? Icons.check : widget.icon,
                          color: fill,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
