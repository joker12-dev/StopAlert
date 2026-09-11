import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show TemplateType;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/favorite_route.dart';
import '../data/journey_record.dart';
import '../state/settings_provider.dart';
import '../services/ad_service.dart';
import '../services/app_review_service.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/native_ad_slot.dart';
import '../util/haptics.dart';
import '../widgets/confetti_overlay.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mascot.dart';
import '../widgets/review_prompt.dart';

/// "İndin" ekranı — varış özeti + yolculuğu Firestore'a kaydeder.
///
/// Plan gereği reklam (geçiş) YALNIZCA bu ekranda gösterilir; kritik alarm
/// akışının tamamen dışındadır.
class ArrivalScreen extends ConsumerStatefulWidget {
  const ArrivalScreen({super.key, required this.record, this.favorite});

  final JourneyRecord record;

  /// Bu yolculuktan üretilen favori adayı (hat + durak kimlikleriyle).
  /// null ise favori eklenemez (ör. hat verisi olmadan başlatılmış yolculuk).
  final FavoriteRoute? favorite;

  @override
  ConsumerState<ArrivalScreen> createState() => _ArrivalScreenState();
}

class _ArrivalScreenState extends ConsumerState<ArrivalScreen> {
  bool _saved = false;
  bool _favorited = false;

  @override
  void initState() {
    super.initState();
    // Yolculuğu bir kez kaydet.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(journeyRepositoryProvider).save(widget.record);
      if (mounted) setState(() => _saved = true);
    });
    // Puan istemini SIRAYA AL — burada göstermeyiz. Kullanıcı henüz varış
    // özetine bakıyor; istem ana sayfaya döndüğünde çıkar.
    unawaited(AppReviewService.onJourneyCompleted());
  }

  String get _durationText {
    final m = widget.record.durationSeconds ~/ 60;
    return m < 1 ? '<1 dk' : '$m dk';
  }

  Future<void> _toggleFavorite() async {
    if (_favorited) return; // yalnızca ekleme (varış anında)
    final favorite = widget.favorite;
    if (favorite == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Bu yolculuk favoriye eklenemedi.'),
        ));
      return;
    }
    setState(() => _favorited = true);
    final added = await ref.read(favoritesRepositoryProvider).add(favorite);
    if (!mounted) return;
    if (!added) {
      // Sessizce yutmak "eklendi" izlenimi bırakıyordu; oysa liste değişmedi.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Bu rota zaten favorilerinde.'),
        ));
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Favorilere eklendi.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final r = widget.record;
    final color = lineTypeColor(r.lineType);

    return Scaffold(
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                children: [
                  // Varış rozeti
                  Center(
                    child: Column(
                      children: [
                        // STOPİ "Harika!" — başarıyla inişin kutlaması.
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: VigilantColors.secondary
                                    .withValues(alpha: 0.25),
                                blurRadius: 60,
                                spreadRadius: 10,
                              ),
                            ],
                          ),
                          child: const AnimatedMascot(MascotAssets.harika,
                              height: 140),
                        ),
                        const SizedBox(height: 16),
                        Text('İndin', style: text.headlineLarge),
                        const SizedBox(height: 4),
                        Text(
                          r.targetStopName,
                          style: text.bodyLarge?.copyWith(
                            color: VigilantColors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  // Yolculuk özeti kartı
                  GlassPanel(
                    borderRadius: 24,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(lineTypeIcon(r.lineType), color: color),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                r.lineName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.titleMediumOrBody,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _RouteRow(
                          icon: Icons.trip_origin,
                          label: 'Biniş',
                          value: r.boardingStopName,
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 11),
                          child: Container(
                            width: 2,
                            height: 20,
                            color: VigilantColors.outlineVariant,
                          ),
                        ),
                        _RouteRow(
                          icon: Icons.place,
                          label: 'İniş',
                          value: r.targetStopName,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _StatTile(
                          value: _durationText,
                          label: 'Süre',
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _StatTile(
                          value: '${r.stopsTraveled}',
                          label: 'Durak',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Anonim katkı: yolculuk sonunda nazik davet (yalnız kapalıysa
                  // ve kullanıcı daha önce kapatmadıysa). Ayarlarda gizli kalıp
                  // kimse görmüyordu.
                  const _ContributeCard(),
                  // Yolculuk özeti ile eylem düğmeleri arasında yerel reklam.
                  // Yüklenmezse hiç yer kaplamaz.
                  const NativeAdSlot(
                    key: ValueKey('arrival-native-ad'),
                    margin: EdgeInsets.only(bottom: 16),
                    template: TemplateType.small,
                  ),
                  // Favori + Paylaş
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _favorited
                                ? VigilantColors.primary
                                : VigilantColors.onSurface,
                            side: BorderSide(
                              color: _favorited
                                  ? VigilantColors.primary
                                  : VigilantColors.outlineVariant,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: _toggleFavorite,
                          icon:
                              Icon(_favorited ? Icons.star : Icons.star_border),
                          label:
                              Text(_favorited ? 'Favoride' : 'Favorilere ekle'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: VigilantColors.onSurface,
                            side: const BorderSide(
                                color: VigilantColors.outlineVariant),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          onPressed: () {
                            ScaffoldMessenger.of(context)
                              ..hideCurrentSnackBar()
                              ..showSnackBar(const SnackBar(
                                content: Text('Paylaşım Faz 3\'te geliyor.'),
                              ));
                          },
                          icon: const Icon(Icons.ios_share),
                          label: const Text('Paylaş'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // PUAN VER — mağazanın yerli akışını açar.
            //
            // İlk yolculuktan sonra kendiliğinden çıkan istem sıklık kotasına
            // takılıp hiç görünmeyebiliyor; memnun kullanıcının kendi
            // isteğiyle basabileceği bir yer de olmalı. Tam burası: yolculuk
            // yeni bitti, kullanıcı alarmın işe yaradığını yeni gördü.
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: SizedBox(
                height: 46,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: VigilantColors.tertiaryContainer,
                    side: BorderSide(
                        color: VigilantColors.tertiaryContainer
                            .withValues(alpha: 0.5)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () async {
                    Haptics.light();
                    // İstem bir daha kendiliğinden çıkmasın: kullanıcı zaten
                    // kendi isteğiyle geldi.
                    await AppReviewService.consumePending();
                    await AppReviewService.request();
                  },
                  icon: const Icon(Icons.star_rounded, size: 18),
                  label: const Text('Uygulamaya puan ver'),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              child: SizedBox(
                height: 56,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: VigilantColors.primary,
                    foregroundColor: VigilantColors.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    textStyle: text.labelLarge,
                  ),
                  onPressed: () async {
                    // Geçiş reklamı (varsa) burada gösterilir; alarm akışının
                    // TAMAMEN dışında, ana sayfaya dönerken.
                    final navigator = Navigator.of(context);
                    await AdService.instance.maybeShowInterstitial();
                    if (!mounted) return;
                    navigator.popUntil((r) => r.isFirst);
                    // Ana sayfaya DÖNDÜKTEN sonra puan istemi (ilk yolculuk).
                    // Sıra önemli: varış ekranının üstünde sorulursa kullanıcı
                    // özetini göremeden diyalogla karşılaşır.
                    if (!await AppReviewService.consumePending()) return;
                    if (!navigator.mounted) return;
                    // Ana sayfa bir kare çizilsin, istem üstüne binmesin.
                    await Future<void>.delayed(
                        const Duration(milliseconds: 450));
                    if (navigator.mounted) {
                      await showReviewPrompt(navigator.context);
                    }
                  },
                  child: Text(_saved ? 'Ana Sayfaya Dön' : 'Kaydediliyor…'),
                ),
              ),
            ),
              ],
            ),
          ),
          // Varış kutlaması — bir kez patlar, dokunuşları geçirir.
          const Positioned.fill(child: ConfettiOverlay()),
        ],
      ),
    );
  }
}

class _RouteRow extends StatelessWidget {
  const _RouteRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(icon, size: 20, color: VigilantColors.primary),
        const SizedBox(width: 12),
        Text(
          label,
          style:
              text.bodyMedium?.copyWith(color: VigilantColors.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(value,
              style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label,
              style: text.bodySmall
                  ?.copyWith(color: VigilantColors.onSurfaceVariant)),
        ],
      ),
    );
  }
}

extension on TextTheme {
  TextStyle? get titleMediumOrBody =>
      bodyLarge?.copyWith(fontWeight: FontWeight.w700);
}

/// Yolculuk sonunda "Anonim katkı" daveti — yalnızca katkı KAPALIYSA ve
/// kullanıcı daha önce kapatmadıysa görünür. Ayarlarda gizli kalıp kimse
/// görmüyordu; en doğru an, sürelerin yeni ölçüldüğü varış anıdır.
class _ContributeCard extends ConsumerStatefulWidget {
  const _ContributeCard();

  @override
  ConsumerState<_ContributeCard> createState() => _ContributeCardState();
}

class _ContributeCardState extends ConsumerState<_ContributeCard> {
  static const _dismissKey = 'contribute_prompt_dismissed_v1';
  bool _dismissed = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _dismissed = p.getBool(_dismissKey) ?? false;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _dismiss() async {
    Haptics.light();
    setState(() => _dismissed = true);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_dismissKey, true);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || _dismissed) return const SizedBox.shrink();
    final on = (ref.watch(settingsProvider).valueOrNull ?? const AppSettings())
        .contributeToCloud;
    // Zaten açıksa davet gösterme.
    if (on) return const SizedBox.shrink();

    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
        border:
            Border.all(color: VigilantColors.primary.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: VigilantColors.primary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.favorite_rounded,
                color: VigilantColors.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Anonim katkı',
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800)),
                    ),
                    InkResponse(
                      onTap: _dismiss,
                      radius: 18,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close_rounded,
                            size: 18, color: VigilantColors.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Bu yolculukta ölçülen durak-arası süreleri ADIN VERİLMEDEN '
                  'paylaş; tahminler herkes için gelişsin. İstediğinde Ayarlar\'dan '
                  'kapatabilirsin.',
                  style: text.bodyMedium?.copyWith(
                      color: VigilantColors.onSurfaceVariant, height: 1.3),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton(
                      onPressed: () {
                        Haptics.light();
                        ref
                            .read(settingsProvider.notifier)
                            .setContributeToCloud(true);
                        ScaffoldMessenger.of(context)
                          ..hideCurrentSnackBar()
                          ..showSnackBar(const SnackBar(
                            content: Text(
                                'Teşekkürler! Anonim katkı açıldı.'),
                          ));
                      },
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                      ),
                      child: const Text('Aç'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _dismiss,
                      child: const Text('Şimdi değil'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
