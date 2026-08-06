import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/recent_search.dart';
import '../data/transit_city.dart';
import '../data/transit_db.dart';
import '../engine/arrival_estimator.dart';
import '../services/live_bus_service.dart';
import '../services/segment_learning_store.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../util/haptics.dart';
import 'alarm_setup_screen.dart';
import 'nearby_map_screen.dart';

/// Bir otobüs durağından geçen hatları TEMİZ, tam ekran olarak sunar. Kullanıcı
/// bu durağı hedef seçmiştir; burada "hangi hatla gidiyorum" der, o hatla alarm
/// kurulur. (Modal yerine net bir ekran — akış karışmasın.)
class StopLinesScreen extends ConsumerStatefulWidget {
  const StopLinesScreen({
    super.key,
    required this.stop,
    required this.lines,
    this.city,
  });

  final Stop stop;
  final List<TransitLineBrief> lines;

  /// Durak BAŞKA şehrin paketindeyse o şehir (aktif şehir değiştirilmez).
  final TransitCity? city;

  @override
  ConsumerState<StopLinesScreen> createState() => _StopLinesScreenState();
}

class _StopLinesScreenState extends ConsumerState<StopLinesScreen> {
  Stop get stop => widget.stop;
  List<TransitLineBrief> get lines => widget.lines;
  TransitCity? get city => widget.city;

  /// Bu durağa yaklaşan otobüsler — en yakın varıştan uzağa sıralı.
  List<_Arrival> _arrivals = const [];
  bool _loadingArrivals = false;
  DateTime? _arrivalsAt;

  /// Kaç hat için canlı konum sorgulanacağı.
  ///
  /// Bir duraktan 30 hat geçebiliyor; hepsi için ayrı çağrı yapmak hem
  /// yavaş hem de İETT'nin saatlik kotasına yüklenmek olurdu. Kullanıcı
  /// pratikte ilk birkaç hatla ilgileniyor.
  static const _maxLinesQueried = 10;

  @override
  void initState() {
    super.initState();
    _loadArrivals();
  }

  /// Şehrin canlı filo servisi varsa yaklaşan otobüsleri hesapla.
  Future<void> _loadArrivals() async {
    final TransitCity lineCity = city ?? ref.read(activeCityProvider);
    if (!lineCity.hasLiveBus) return;
    setState(() => _loadingArrivals = true);

    final learner = await SegmentLearningStore.load();
    final found = <_Arrival>[];

    for (final brief in lines.take(_maxLinesQueried)) {
      try {
        final line =
            await TransitDb.instance.buildLine(brief.id, cityId: city?.id);
        if (line == null || line.indexOfStop(stop.id) <= 0) continue;

        final all = await LiveBusService.instance.vehicles(brief.code);
        // Yalnızca BU yöndeki araçlar: karşı yöndeki otobüsün varışını
        // göstermek kullanıcıyı yanlış otobüse bindirir.
        final isGidis = line.id.endsWith('_G');
        final sameWay = [
          for (final v in all)
            if (v.routeCode.contains('_G_') || v.routeCode.contains('_D_'))
              if (v.isGidis == isGidis) v,
        ];
        if (sameWay.isEmpty) continue;

        final ests = ArrivalEstimator.forStop(
          line: line,
          targetStopId: stop.id,
          vehicles: sameWay,
          learner: learner,
        );
        for (final e in ests) {
          found.add(_Arrival(brief: brief, line: line, estimate: e));
        }
      } catch (_) {
        // Tek hattın verisi alınamadıysa ötekiler yine gösterilir.
      }
    }

    found.sort((a, b) => a.estimate.seconds.compareTo(b.estimate.seconds));
    if (!mounted) return;
    setState(() {
      _arrivals = found;
      _loadingArrivals = false;
      _arrivalsAt = DateTime.now();
    });
  }

  Future<void> _pick(
      BuildContext context, WidgetRef ref, TransitLineBrief brief) async {
    Haptics.light();
    final line =
        await TransitDb.instance.buildLine(brief.id, cityId: city?.id);
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

  /// "Yaklaşan otobüsler" bloğu — hiç canlı veri yoksa hiç çizilmez.
  List<Widget> _arrivalsSection(TextTheme text) {
    final TransitCity lineCity = city ?? ref.read(activeCityProvider);
    if (!lineCity.hasLiveBus) return const [];
    if (!_loadingArrivals && _arrivals.isEmpty && _arrivalsAt == null) {
      return const [];
    }
    return [
      Row(
        children: [
          const Icon(Icons.directions_bus_filled_rounded,
              size: 16, color: VigilantColors.secondary),
          const SizedBox(width: 8),
          Text('YAKLAŞAN OTOBÜSLER',
              style: text.labelSmall?.copyWith(
                  color: VigilantColors.onSurfaceVariant, letterSpacing: 1.2)),
          const Spacer(),
          if (_loadingArrivals)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            InkResponse(
              onTap: () {
                Haptics.light();
                _loadArrivals();
              },
              radius: 20,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.refresh_rounded,
                    size: 18, color: VigilantColors.onSurfaceVariant),
              ),
            ),
        ],
      ),
      const SizedBox(height: 10),
      if (_arrivals.isEmpty && !_loadingArrivals)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            'Şu an bu durağa yaklaşan otobüs görünmüyor.',
            style:
                text.labelMedium?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        )
      else
        for (final a in _arrivals.take(6)) ...[
          _ArrivalRow(
            arrival: a,
            onTap: () => _pick(context, ref, a.brief),
          ),
          const SizedBox(height: 8),
        ],
      // Tahminin ne olduğunu SÖYLE: 60 saniyede bir yayın yapan bir
      // beslemeden tek dakikalık kesinlik çıkmaz, aralık gösteriyoruz.
      if (_arrivals.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Text(
            'Süreler canlı konumdan tahmin edilir; konum ~1 dakikada bir '
            'güncellenir.',
            style: text.labelSmall
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        ),
      const SizedBox(height: 18),
      Row(
        children: [
          const Icon(Icons.alt_route_rounded,
              size: 16, color: VigilantColors.primary),
          const SizedBox(width: 8),
          Text('BU DURAKTAN GEÇEN HATLAR',
              style: text.labelSmall?.copyWith(
                  color: VigilantColors.onSurfaceVariant, letterSpacing: 1.2)),
        ],
      ),
      const SizedBox(height: 10),
    ];
  }

  @override
  Widget build(BuildContext context) {
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
                  if (stop.contextLabel.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(stop.contextLabel,
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
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                    20, 0, 20, AppInsets.pageBottom(context)),
                children: [
                  ..._arrivalsSection(text),
                  for (var i = 0; i < lines.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    _LineCard(
                      brief: lines[i],
                      onTap: () => _pick(context, ref, lines[i]),
                    ),
                  ],
                ],
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

/// Bir hattın tek bir otobüsünün bu durağa varış tahmini.
class _Arrival {
  const _Arrival({
    required this.brief,
    required this.line,
    required this.estimate,
  });

  final TransitLineBrief brief;
  final TransitLine line;
  final ArrivalEstimate estimate;
}

/// Yaklaşan tek otobüs satırı.
class _ArrivalRow extends StatelessWidget {
  const _ArrivalRow({required this.arrival, required this.onTap});

  final _Arrival arrival;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final e = arrival.estimate;
    final imminent = e.maxSeconds <= 120;
    final accent =
        imminent ? VigilantColors.secondary : VigilantColors.onSurface;

    return Material(
      color: VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Container(
                constraints: const BoxConstraints(minWidth: 48),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: VigilantColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(arrival.brief.code,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleSmall?.copyWith(
                        color: VigilantColors.primary,
                        fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      arrival.line.stops.last.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${e.stopsAway} durak uzakta'
                      '${e.quality == ArrivalQuality.schedule ? " · tarifeye göre" : ""}',
                      style: text.labelSmall
                          ?.copyWith(color: VigilantColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                e.rangeLabel,
                style: text.titleMedium?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
