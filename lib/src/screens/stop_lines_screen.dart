import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/recent_search.dart';
import '../data/transit_db.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import 'alarm_setup_screen.dart';
import 'nearby_map_screen.dart';

/// Bir otobüs durağından geçen hatları TEMİZ, tam ekran olarak sunar. Kullanıcı
/// bu durağı hedef seçmiştir; burada "hangi hatla gidiyorum" der, o hatla alarm
/// kurulur. (Modal yerine net bir ekran — akış karışmasın.)
class StopLinesScreen extends ConsumerWidget {
  const StopLinesScreen({super.key, required this.stop, required this.lines});

  final Stop stop;
  final List<TransitLineBrief> lines;

  Future<void> _pick(
      BuildContext context, WidgetRef ref, TransitLineBrief brief) async {
    Haptics.light();
    final line = await TransitDb.instance.buildLine(brief.id);
    if (!context.mounted) return;
    if (line == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text('Hat verisi yüklenemedi — tekrar dene.')));
      return;
    }
    // Seçilen durağı hatta bul (aynı bus: önekli id).
    var target = stop;
    final i = line.indexOfStop(stop.id);
    if (i != -1) target = line.stops[i];
    ref.read(journeyDraftProvider.notifier)
      ..reset()
      ..selectLine(line)
      ..selectTargetStop(target.id);
    ref.read(recentSearchesProvider.notifier).add(RecentSearch(
          stopName: target.name,
          stopId: target.id,
          lineId: line.id,
          lineCode: line.code,
          lineTypeName: line.type.name,
        ));
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          AlarmSetupScreen(stopName: target.name, lineLabel: line.code),
    ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back,
                        color: VigilantColors.onSurfaceVariant),
                  ),
                  const Spacer(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.location_on,
                          size: 16, color: VigilantColors.primary),
                      const SizedBox(width: 6),
                      Text('İNECEĞİN DURAK',
                          style: text.labelSmall?.copyWith(
                              color: VigilantColors.onSurfaceVariant,
                              letterSpacing: 1.2)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(stop.name, style: text.headlineSmall),
                  if (stop.direction.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(stop.direction,
                          style: text.labelMedium
                              ?.copyWith(color: VigilantColors.secondary)),
                    ),
                  const SizedBox(height: 10),
                  Text('Hangi otobüse bineceksin? Seçince o hatta bu durağa '
                      'yaklaşınca seni uyarırım.',
                      style: text.bodyMedium
                          ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                  const SizedBox(height: 12),
                  // Durağı haritada göster (konumdan yürüme rotasıyla).
                  SizedBox(
                    height: 44,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: VigilantColors.onSurface,
                        side: BorderSide(
                            color: VigilantColors.surfaceVariant
                                .withValues(alpha: 0.6)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: () {
                        Haptics.light();
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => NearbyMapScreen(focusStop: stop),
                        ));
                      },
                      icon: const Icon(Icons.map_rounded,
                          size: 18, color: VigilantColors.primary),
                      label: const Text('Haritada görüntüle'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
                itemCount: lines.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  final l = lines[i];
                  return _LineCard(brief: l, onTap: () => _pick(context, ref, l));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({required this.brief, required this.onTap});

  final TransitLineBrief brief;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                constraints: const BoxConstraints(minWidth: 52),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: VigilantColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(brief.code,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleMedium?.copyWith(
                        color: VigilantColors.primary,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(brief.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.alarm_add_rounded,
                  color: VigilantColors.primary, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}
