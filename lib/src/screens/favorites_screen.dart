import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/favorite_route.dart';
import '../data/journey_payload.dart';
import '../data/models.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../widgets/native_ad_slot.dart';
import '../widgets/glass_panel.dart';
import '../widgets/mascot.dart';
import 'live_tracking_screen.dart';
import 'search_screen.dart';

/// Favoriler — Firestore'daki gerçek favori rotalar; tek dokunuşla başlatılır.
class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final favorites =
        ref.watch(favoritesStreamProvider).valueOrNull ?? const [];

    return Scaffold(
      floatingActionButton: Padding(
        // Alt menü `extendBody: true` ile içeriğin ÜSTÜNDE duruyor; sabit
        // 88 px sistem gezinme çubuğu olan cihazlarda yetmiyordu ve düğme
        // menünün altında kalıyordu.
        padding: EdgeInsets.only(
            bottom: 88 + MediaQuery.viewPaddingOf(context).bottom),
        child: FloatingActionButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const SearchScreen(asPage: true),
            ),
          ),
          backgroundColor: VigilantColors.primary,
          foregroundColor: VigilantColors.onPrimary,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: const Icon(Icons.add, size: 28),
        ),
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(20, 8, 20, AppInsets.listBottom(context)),
          children: [
            // Başlık
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: VigilantColors.surfaceVariant,
                  ),
                  child: const Icon(Icons.person_outline,
                      color: VigilantColors.onSurfaceVariant, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Favoriler',
                      style: text.headlineSmall?.copyWith(letterSpacing: -0.5)),
                ),
                IconButton(
                  onPressed: () => ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(
                      content: Text('Bildirim merkezi yakında.'),
                    )),
                  icon: const Icon(Icons.notifications_none_rounded,
                      color: VigilantColors.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text('Favori Rotalar', style: text.headlineSmall),
            const SizedBox(height: 12),
            if (favorites.isEmpty)
              _EmptyFavorites(text: text)
            else
              for (final fav in favorites) ...[
                _RouteCard(
                  favorite: fav,
                  onPlay: () => _start(context, ref, fav),
                  onDelete: () =>
                      ref.read(favoritesRepositoryProvider).remove(fav.id),
                ),
                const SizedBox(height: 12),
              ],
            const SizedBox(height: 8),
            // Liste sonunda YEREL reklam: içeriği bölmüyor, kullanıcı
            // aradığını bulduktan sonra karşısına çıkıyor.
            const NativeAdSlot(margin: EdgeInsets.only(top: 20)),
          ],
        ),
      ),
    );
  }

  void _start(BuildContext context, WidgetRef ref, FavoriteRoute fav) {
    final lines = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
    TransitLine? line;
    for (final l in lines) {
      if (l.id == fav.lineId) {
        line = l;
        break;
      }
    }
    if (line == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Hat verisi yüklenemedi, tekrar dene.'),
        ));
      return;
    }
    final resolvedLine = line;
    if (resolvedLine.indexOfStop(fav.boardingStopId) == -1 ||
        resolvedLine.indexOfStop(fav.targetStopId) == -1) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Bu favorinin durakları güncel hat verisinde yok.'),
        ));
      return;
    }
    ref.read(journeyDraftProvider.notifier)
      ..reset()
      ..selectLine(resolvedLine)
      ..selectBoardingStop(fav.boardingStopId)
      ..selectTargetStop(fav.targetStopId);
    final payload = JourneyPayload(
      line: resolvedLine,
      boardingStopId: fav.boardingStopId,
      targetStopId: fav.targetStopId,
      alarmDistanceMeters: 500,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LiveTrackingScreen(payload: payload),
      ),
    );
  }
}

class _EmptyFavorites extends StatelessWidget {
  const _EmptyFavorites({required this.text});

  final TextTheme text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          // STOPİ "İyi yolculuklar!" — ilk favoriye davet.
          const Mascot(MascotAssets.iyiYolculuklar, height: 120),
          const SizedBox(height: 10),
          Text(
            'Henüz favori rota yok.\nBir yolculuk tamamlayıp "Favorilere ekle" '
            'dediğinde ya da alttaki + ile buraya eklenir.',
            textAlign: TextAlign.center,
            style: text.bodyMedium
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.favorite,
    required this.onPlay,
    required this.onDelete,
  });

  final FavoriteRoute favorite;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = lineTypeColor(favorite.lineType);
    return GlassPanel(
      borderRadius: 24,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: VigilantColors.surfaceContainer,
            ),
            child: Icon(lineTypeIcon(favorite.lineType), color: color),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  favorite.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  '${favorite.lineCode} • ${favorite.lineName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelMedium
                      ?.copyWith(color: VigilantColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: onDelete,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_outline,
                color: VigilantColors.onSurfaceVariant),
          ),
          GestureDetector(
            onTap: onPlay,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: VigilantColors.primary,
                boxShadow: [
                  BoxShadow(
                    color: VigilantColors.primary.withValues(alpha: 0.4),
                    blurRadius: 15,
                  ),
                ],
              ),
              child:
                  const Icon(Icons.play_arrow, color: VigilantColors.onPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
