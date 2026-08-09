import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/transit_city.dart';
import '../data/transit_db.dart';
import '../services/bus_data_service.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/insets.dart';
import '../widgets/skeleton.dart';
import 'nearby_map_screen.dart';
import 'stop_lines_screen.dart';

/// DURAKLAR sekmesi — yalnızca durak arama.
///
/// Hatlar sekmesi hat arıyor, burası durak: ikisi tek listede karışınca
/// "Şişli" yazan kullanıcı ne aradığını bulamıyordu. Boş sorguda yakındaki
/// duraklar listelenir — durak arayan kişinin çoğu zaman aradığı zaten
/// yanı başındaki duraktır.
class StopsScreen extends ConsumerStatefulWidget {
  const StopsScreen({super.key});

  @override
  ConsumerState<StopsScreen> createState() => _StopsScreenState();
}

class _StopsScreenState extends ConsumerState<StopsScreen> {
  final _controller = TextEditingController();
  String _query = '';
  List<Stop> _results = const [];
  bool _searching = false;

  /// Arama sırası — geç dönen eski sorgu yenisini ezmesin.
  int _seq = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String raw) async {
    final q = raw.trim();
    setState(() => _query = q);
    if (q.length < 2) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    final seq = ++_seq;
    setState(() => _searching = true);

    final city = ref.read(activeCityProvider);
    final out = <String, Stop>{};

    // 1) İndirilen paketteki duraklar (İstanbul 13.000, Kocaeli 8.400).
    try {
      for (final s in await TransitDb.instance.searchStops(q, limit: 40)) {
        out.putIfAbsent('${s.name}|${s.direction}', () => s);
      }
    } catch (_) {
      // Paket yok: yalnızca ray/vapur durakları listelenir.
    }

    // 2) Ray/vapur durakları ayrı kaynakta (gömülü/indirilen JSON).
    final norm = transitNorm(q);
    final rail = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
    for (final l in rail) {
      for (final s in l.stops) {
        if (!transitNorm(s.name).contains(norm)) continue;
        out.putIfAbsent('${s.name}|${s.direction}', () => s);
      }
    }

    if (!mounted || seq != _seq) return;
    setState(() {
      _results = out.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      _searching = false;
      // Şehir etiketi için (aktif şehirde arıyoruz).
      _city = city;
    });
  }

  TransitCity? _city;

  /// Durak künyesini aç: yaklaşan otobüsler + duraktan geçen hatlar.
  Future<void> _open(Stop stop) async {
    Haptics.light();
    var lines = const <TransitLineBrief>[];
    if (isBusId(stop.id)) {
      lines = await TransitDb.instance.linesForStop(stop.id);
    } else {
      // Ray/vapur: durağı içeren hatları gömülü listeden topla.
      final rail = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
      lines = [
        for (final l in rail)
          if (l.stops.any((s) => s.id == stop.id))
            TransitLineBrief(
                id: l.id, code: l.code, name: l.name, type: l.type),
      ];
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StopLinesScreen(stop: stop, lines: lines),
    ));
  }

  Future<void> _switchCity(TransitCity city) async {
    if (city.id == ref.read(activeCityProvider).id) return;
    Haptics.selection();
    await ref.read(cityProvider.notifier).select(city);
    await BusDataService.instance.ensureReady(city: city);
    if (!mounted) return;
    ref.invalidate(linesProvider);
    ref.invalidate(nearbyStopsProvider);
    if (_query.isNotEmpty) await _search(_query);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final city = ref.watch(activeCityProvider);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Durak Ara',
                        style: text.headlineSmall?.copyWith(fontSize: 20)),
                  ),
                  PopupMenuButton<TransitCity>(
                    tooltip: 'Şehir',
                    onSelected: _switchCity,
                    itemBuilder: (context) => [
                      for (final c in TransitCities.all)
                        PopupMenuItem(
                          value: c,
                          child: Row(
                            children: [
                              Icon(
                                c.id == city.id
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                size: 18,
                                color: c.id == city.id
                                    ? VigilantColors.primary
                                    : VigilantColors.onSurfaceVariant,
                              ),
                              const SizedBox(width: 10),
                              Text(c.name),
                            ],
                          ),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.location_city_rounded, size: 18),
                          const SizedBox(width: 6),
                          Text(city.name, style: text.labelLarge),
                          const Icon(Icons.arrow_drop_down, size: 20),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: TextField(
                controller: _controller,
                onChanged: _search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: VigilantColors.surfaceContainer,
                  hintText: 'Durak adı ara…',
                  prefixIcon: const Icon(Icons.search,
                      color: VigilantColors.primary),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _controller.clear();
                            _search('');
                          },
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(child: _body(text)),
          ],
        ),
      ),
    );
  }

  Widget _body(TextTheme text) {
    if (_query.isEmpty) return _nearby(text);
    if (_searching && _results.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        children: const [
          SkeletonTile(),
          SizedBox(height: 12),
          SkeletonTile(),
        ],
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            _query.length < 2
                ? 'Aramak için en az iki harf yaz.'
                : 'Durak bulunamadı.',
            textAlign: TextAlign.center,
            style: text.bodyMedium
                ?.copyWith(color: VigilantColors.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(20, 0, 20, AppInsets.listBottom(context)),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, i) => _StopTile(
        stop: _results[i],
        cityLabel: _city?.name,
        onTap: () => _open(_results[i]),
      ),
    );
  }

  /// Boş sorgu: yakındaki duraklar + haritada gör kısayolu.
  Widget _nearby(TextTheme text) {
    final nearby = ref.watch(nearbyStopsProvider);
    return ListView(
      padding: EdgeInsets.fromLTRB(20, 0, 20, AppInsets.listBottom(context)),
      children: [
        SizedBox(
          height: 46,
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: VigilantColors.onSurface,
              side: BorderSide(
                  color:
                      VigilantColors.surfaceVariant.withValues(alpha: 0.6)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: () {
              Haptics.light();
              Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const NearbyMapScreen(),
              ));
            },
            icon: const Icon(Icons.map_rounded,
                size: 18, color: VigilantColors.primary),
            label: const Text('Haritada duraklar'),
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            const Icon(Icons.near_me_outlined,
                size: 16, color: VigilantColors.onSurfaceVariant),
            const SizedBox(width: 8),
            Text('YAKINDAKİ DURAKLAR',
                style: text.labelSmall?.copyWith(
                    color: VigilantColors.onSurfaceVariant,
                    letterSpacing: 1.2)),
          ],
        ),
        const SizedBox(height: 12),
        ...nearby.when(
          loading: () => const [
            SkeletonTile(),
            SizedBox(height: 12),
            SkeletonTile(),
          ],
          error: (_, __) => [
            Text('Yakındaki duraklar alınamadı.',
                style: text.labelMedium
                    ?.copyWith(color: VigilantColors.onSurfaceVariant)),
          ],
          data: (hits) => hits.isEmpty
              ? [
                  Text(
                    'Konum yoksa yakındaki duraklar listelenemez — '
                    'yukarıdan arayabilirsin.',
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                ]
              : [
                  for (final h in hits.take(12)) ...[
                    _StopTile(
                      stop: h.stop,
                      meters: h.meters,
                      onTap: () => _open(h.stop),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
        ),
      ],
    );
  }
}

class _StopTile extends StatelessWidget {
  const _StopTile({
    required this.stop,
    required this.onTap,
    this.meters,
    this.cityLabel,
  });

  final Stop stop;
  final VoidCallback onTap;
  final double? meters;
  final String? cityLabel;

  String get _distance {
    final m = meters;
    if (m == null) return '';
    return m >= 1000
        ? '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
        : '${m.round()} m';
  }

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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: VigilantColors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.location_on_outlined,
                    size: 20, color: VigilantColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(stop.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleSmall),
                    if (stop.contextLabel.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(stop.contextLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelSmall?.copyWith(
                              color: VigilantColors.onSurfaceVariant)),
                    ],
                  ],
                ),
              ),
              if (_distance.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(_distance,
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.primary)),
              ],
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
