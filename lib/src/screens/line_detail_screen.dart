import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/recent_search.dart';
import '../data/transit_db.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../util/haptics.dart';
import '../widgets/skeleton.dart';
import 'alarm_setup_screen.dart';
import 'live_bus_screen.dart';

/// Tek otobüs hattı sayfası (İETT tarzı): "MK13" → NORMAL gidiş/dönüş +
/// ayrı DEPAR güzergâhları. Kullanıcı güzergâhı/yönü seçer, ineceği durağa
/// dokununca alarm kurulur. Depar (garaj/özel sefer) normalle karışmaz.
class LineDetailScreen extends ConsumerStatefulWidget {
  const LineDetailScreen({super.key, required this.code});

  final String code;

  @override
  ConsumerState<LineDetailScreen> createState() => _LineDetailScreenState();
}

class _LineDetailScreenState extends ConsumerState<LineDetailScreen> {
  LineVariant? _gidis;
  LineVariant? _donus;
  List<LineVariant> _depar = const [];
  String? _selectedId;
  TransitLine? _line;
  bool _loading = true;
  bool _deparOpen = false;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  LineVariant? _firstDir(List<LineVariant> v, String d) {
    for (final x in v) {
      if (!x.depar && x.dir == d) return x; // liste durak sayısına göre azalan
    }
    return null;
  }

  Future<void> _load() async {
    final v = await TransitDb.instance.directionsForCode(widget.code);
    if (!mounted) return;
    _gidis = _firstDir(v, 'G');
    _donus = _firstDir(v, 'D');
    _depar = [for (final x in v) if (x.depar) x];
    // Yön etiketi olmayan normal varyant (nadiren): ilk normali gidiş say.
    if (_gidis == null && _donus == null) {
      final normal = [for (final x in v) if (!x.depar) x];
      if (normal.isNotEmpty) {
        _gidis = normal.first;
      } else if (_depar.isNotEmpty) {
        // Hiç normal yok: depar'ı doğrudan göster.
        _gidis = _depar.first;
        _depar = _depar.skip(1).toList();
      }
    }
    _selectedId = (_gidis ?? _donus)?.id;
    await _loadSelected();
  }

  Future<void> _loadSelected() async {
    final id = _selectedId;
    if (id == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    final line = await TransitDb.instance.buildLine(id);
    if (!mounted) return;
    setState(() {
      _line = line;
      _loading = false;
    });
  }

  void _select(String id) {
    if (_selectedId == id) return;
    Haptics.selection();
    _selectedId = id;
    _filter = '';
    _loadSelected();
  }

  bool get _selectedIsDepar => _depar.any((d) => d.id == _selectedId);

  void _pickTarget(Stop stop) {
    final line = _line;
    if (line == null) return;
    Haptics.light();
    ref.read(journeyDraftProvider.notifier)
      ..reset()
      ..selectLine(line)
      ..selectTargetStop(stop.id);
    ref.read(recentSearchesProvider.notifier).add(RecentSearch(
          stopName: stop.name,
          stopId: stop.id,
          lineId: line.id,
          lineCode: line.code,
          lineTypeName: line.type.name,
        ));
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          AlarmSetupScreen(stopName: stop.name, lineLabel: line.code),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final line = _line;
    final q = _filter.trim().toLowerCase();
    final stops = (line == null || q.isEmpty)
        ? (line?.stops ?? const <Stop>[])
        : [
            for (final s in line.stops)
              if (s.name.toLowerCase().contains(q)) s
          ];

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(text),
            const SizedBox(height: 12),
            // Kaydırılabilir üst alan (yön seçimi + depar); durak listesi ayrı.
            Flexible(
              flex: 0,
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_gidis != null || _donus != null)
                        Row(
                          children: [
                            if (_gidis != null)
                              Expanded(
                                child: _DirTab(
                                  label: 'Gidiş',
                                  sub: _gidis!.name,
                                  selected: _selectedId == _gidis!.id,
                                  onTap: () => _select(_gidis!.id),
                                ),
                              ),
                            if (_gidis != null && _donus != null)
                              const SizedBox(width: 10),
                            if (_donus != null)
                              Expanded(
                                child: _DirTab(
                                  label: 'Dönüş',
                                  sub: _donus!.name,
                                  selected: _selectedId == _donus!.id,
                                  onTap: () => _select(_donus!.id),
                                ),
                              ),
                          ],
                        ),
                      if (_depar.isNotEmpty) _deparSection(text),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Text('İneceğin durağı seç',
                      style: text.headlineSmall?.copyWith(fontSize: 18)),
                  const Spacer(),
                  if (line != null)
                    Text('${line.stops.length} durak',
                        style: text.labelMedium
                            ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                ],
              ),
            ),
            if (_selectedIsDepar)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                child: _banner('Depar güzergâhı — yalnızca işaretli saatlerde'),
              ),
            if (line != null && line.stops.length > 12)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: _searchField(text),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      children: const [
                        SkeletonTile(),
                        SizedBox(height: 12),
                        SkeletonTile(),
                        SizedBox(height: 12),
                        SkeletonTile(),
                      ],
                    )
                  : ListView.builder(
                      padding: EdgeInsets.fromLTRB(20, 0, 20, AppInsets.pageBottom(context)),
                      itemCount: stops.length,
                      itemBuilder: (context, i) {
                        final stop = stops[i];
                        final isLast = q.isEmpty && i == stops.length - 1;
                        return _StopRow(
                          name: stop.name,
                          index: q.isEmpty ? i + 1 : null,
                          isLast: isLast,
                          onTap: () => _pickTarget(stop),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(TextTheme text) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 20, 0),
        child: Row(
          children: [
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back,
                  color: VigilantColors.onSurfaceVariant),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: VigilantColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.directions_bus_filled_rounded,
                      size: 18, color: VigilantColors.primary),
                  const SizedBox(width: 8),
                  Text(widget.code,
                      style: text.titleMedium?.copyWith(
                          color: VigilantColors.primary,
                          fontWeight: FontWeight.w800)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text('Otobüs Hattı',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium
                      ?.copyWith(color: VigilantColors.onSurfaceVariant)),
            ),
            // Canlı araç konumları ("otobüsüm nerede"). Yalnızca canlı filo
            // servisi olan şehirlerde: İETT açık servis veriyor, Kocaeli
            // vermiyor — olmayan özelliği düğme olarak göstermek ölü dokunuş.
            if (_line case final l? when ref.watch(activeCityProvider).hasLiveBus)
              IconButton(
                tooltip: 'Otobüsler nerede',
                onPressed: () {
                  Haptics.light();
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => LiveBusScreen(line: l)));
                },
                icon: const Icon(Icons.travel_explore_rounded,
                    color: VigilantColors.primary),
              ),
          ],
        ),
      );

  Widget _deparSection(TextTheme text) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _deparOpen = !_deparOpen),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.local_shipping_outlined,
                      size: 18, color: VigilantColors.tertiaryContainer),
                  const SizedBox(width: 8),
                  Text('Depar Güzergahları (${_depar.length})',
                      style: text.labelLarge?.copyWith(
                          color: VigilantColors.tertiaryContainer,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Icon(_deparOpen ? Icons.expand_less : Icons.expand_more,
                      color: VigilantColors.tertiaryContainer),
                ],
              ),
            ),
          ),
          if (_deparOpen)
            for (final d in _depar)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _DeparRow(
                  variant: d,
                  selected: _selectedId == d.id,
                  onTap: () => _select(d.id),
                ),
              ),
        ],
      ),
    );
  }

  Widget _banner(String message) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: VigilantColors.tertiaryContainer.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: VigilantColors.tertiaryContainer.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.info_outline,
                size: 15, color: VigilantColors.tertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: VigilantColors.tertiaryContainer)),
            ),
          ],
        ),
      );

  Widget _searchField(TextTheme text) => TextField(
        style: text.bodyMedium,
        onChanged: (v) => setState(() => _filter = v),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: VigilantColors.surfaceContainer,
          prefixIcon: const Icon(Icons.search,
              color: VigilantColors.onSurfaceVariant),
          hintText: 'Durak ara',
          hintStyle:
              text.bodyMedium?.copyWith(color: VigilantColors.onSurfaceVariant),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      );
}

/// Gidiş/dönüş sekmesi (üstte etiket, altta güzergâh adı).
class _DirTab extends StatelessWidget {
  const _DirTab({
    required this.label,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? VigilantColors.primary.withValues(alpha: 0.15)
              : VigilantColors.surfaceContainer,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? VigilantColors.primary
                : VigilantColors.surfaceVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 16,
                    color: selected
                        ? VigilantColors.primary
                        : VigilantColors.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(label,
                    style: text.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: selected
                            ? VigilantColors.primary
                            : VigilantColors.onSurface)),
              ],
            ),
            const SizedBox(height: 4),
            Text(sub,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: text.labelSmall
                    ?.copyWith(color: VigilantColors.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Depar güzergâh satırı (açılır listede).
class _DeparRow extends StatelessWidget {
  const _DeparRow({
    required this.variant,
    required this.selected,
    required this.onTap,
  });

  final LineVariant variant;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? VigilantColors.tertiaryContainer.withValues(alpha: 0.12)
              : VigilantColors.surfaceContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? VigilantColors.tertiaryContainer
                : VigilantColors.surfaceVariant.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                size: 16,
                color: selected
                    ? VigilantColors.tertiaryContainer
                    : VigilantColors.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(variant.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium),
            ),
            const SizedBox(width: 8),
            Text('${variant.stopCount}',
                style: text.labelMedium
                    ?.copyWith(color: VigilantColors.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

class _StopRow extends StatelessWidget {
  const _StopRow({
    required this.name,
    required this.index,
    required this.isLast,
    required this.onTap,
  });

  final String name;
  final int? index;
  final bool isLast;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    const color = VigilantColors.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.15),
              ),
              child: isLast
                  ? const Icon(Icons.flag_rounded, size: 16, color: color)
                  : Text(index?.toString() ?? '•',
                      style: text.labelMedium?.copyWith(
                          color: color, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium),
            ),
            const Icon(Icons.alarm_add_rounded,
                size: 20, color: VigilantColors.primary),
          ],
        ),
      ),
    );
  }
}
