import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/journey_record.dart';
import '../data/models.dart';
import '../services/bus_data_service.dart';
import '../data/transit_db.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/insets.dart';
import 'line_detail_screen.dart';

/// "Tümü" sayfası — en sık kullanılan hatların / en sık inilen durakların
/// TAM sıralı listesi.
///
/// Ana sayfadaki içgörü kartı yalnızca ilk 3'ü gösteriyordu; "Tümü" düğmesi
/// ise sekme değiştirip kullanıcıyı yolculuk geçmişinden koparıyordu. Bu sayfa
/// aynı geçmişten üretilen sıralamayı sonuna kadar açar ve her satır doğrudan
/// o hatta/durağa götürür (alarm kurmaya bir dokunuş kalır).
enum MostUsedMode { lines, stops }

class MostUsedScreen extends ConsumerWidget {
  const MostUsedScreen({
    super.key,
    required this.mode,
    required this.onOpenStop,
  });

  final MostUsedMode mode;

  /// Durağı açan geri çağrı (ana sayfanınkiyle aynı: hatları çözüp alarm
  /// akışına götürür).
  final void Function(TransitLine? line, Stop stop) onOpenStop;

  static List<({String code, String name, LineType type, int count})> topLines(
      List<JourneyRecord> js) {
    final map =
        <String, ({String code, String name, LineType type, int count})>{};
    for (final j in js) {
      if (j.lineCode.isEmpty) continue;
      final key = '${j.lineTypeName}|${j.lineCode}|${j.lineName}';
      final cur = map[key];
      map[key] = (
        code: j.lineCode,
        name: j.lineName,
        type: j.lineType,
        count: (cur?.count ?? 0) + 1,
      );
    }
    return map.values.toList()..sort((a, b) => b.count - a.count);
  }

  static List<({String name, int count})> topStops(List<JourneyRecord> js) {
    final map = <String, int>{};
    for (final j in js) {
      final name = j.targetStopName.trim();
      if (name.isEmpty) continue;
      map[name] = (map[name] ?? 0) + 1;
    }
    final list = map.entries.toList()..sort((a, b) => b.value - a.value);
    return list.map((e) => (name: e.key, count: e.value)).toList();
  }

  Future<void> _openStopByName(BuildContext context, String name) async {
    Haptics.light();
    try {
      await BusDataService.instance.openAllForLookup();
      final matches = await TransitDb.instance.searchStops(name, limit: 1);
      if (!context.mounted || matches.isEmpty) return;
      onOpenStop(null, matches.first);
    } catch (_) {
      // Durak çözülemedi: sessizce geç.
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final isLines = mode == MostUsedMode.lines;
    final journeys =
        ref.watch(journeysStreamProvider).valueOrNull ?? const <JourneyRecord>[];
    final lines = isLines ? topLines(journeys) : const [];
    final stops = isLines ? const [] : topStops(journeys);
    final count = isLines ? lines.length : stops.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(isLines ? 'En Sık Kullanılan Hatlar' : 'En Sık İnilen Duraklar'),
      ),
      body: SafeArea(
        top: false,
        child: count == 0
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    isLines
                        ? 'Henüz yeterli yolculuk yok. Hatlarla yolculuk yaptıkça '
                            'en sık kullandıkların burada sıralanır.'
                        : 'Henüz yeterli yolculuk yok. İndiğin duraklar biriktikçe '
                            'en sık kullandıkların burada sıralanır.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                ),
              )
            : ListView.separated(
                padding: EdgeInsets.fromLTRB(
                    16, 12, 16, AppInsets.pageBottom(context)),
                itemCount: count,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  if (isLines) {
                    final ln = lines[i];
                    return _MostUsedRow(
                      rank: i + 1,
                      count: ln.count,
                      leading: Container(
                        constraints: const BoxConstraints(minWidth: 46),
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: lineTypeColor(ln.type),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(ln.code,
                            style: text.labelLarge?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w800)),
                      ),
                      title: ln.name.isEmpty ? '—' : ln.name,
                      onTap: () {
                        Haptics.light();
                        Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => LineDetailScreen(
                                code: ln.code, type: ln.type)));
                      },
                    );
                  }
                  final s = stops[i];
                  return _MostUsedRow(
                    rank: i + 1,
                    count: s.count,
                    leading: Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: VigilantColors.primary.withValues(alpha: 0.14),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.place_rounded,
                          size: 20, color: VigilantColors.primary),
                    ),
                    title: s.name,
                    onTap: () => _openStopByName(context, s.name),
                  );
                },
              ),
      ),
    );
  }
}

/// Sıra numarası + görsel + ad + kullanım rozeti taşıyan tıklanabilir satır.
class _MostUsedRow extends StatelessWidget {
  const _MostUsedRow({
    required this.rank,
    required this.leading,
    required this.title,
    required this.count,
    required this.onTap,
  });

  final int rank;
  final Widget leading;
  final String title;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: Text('$rank',
                    textAlign: TextAlign.center,
                    style: text.titleMedium?.copyWith(
                        color: VigilantColors.onSurfaceVariant,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 8),
              leading,
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(
                        color: VigilantColors.onSurface,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: VigilantColors.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.repeat_rounded,
                        size: 13, color: VigilantColors.primary),
                    const SizedBox(width: 4),
                    Text('$count',
                        style: text.labelMedium?.copyWith(
                            color: VigilantColors.primary,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded,
                  size: 20, color: VigilantColors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
