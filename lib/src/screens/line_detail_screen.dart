import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/recent_search.dart';
import '../data/transit_city.dart';
import '../data/transit_db.dart';
import '../services/live_bus_service.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../util/haptics.dart';
import '../widgets/skeleton.dart';
import 'alarm_setup_screen.dart';
import 'live_bus_screen.dart';
import 'route_map_screen.dart';

/// Tek otobüs hattı sayfası (İETT tarzı): "MK13" → NORMAL gidiş/dönüş +
/// ayrı DEPAR güzergâhları. Kullanıcı güzergâhı/yönü seçer, ineceği durağa
/// dokununca alarm kurulur. Depar (garaj/özel sefer) normalle karışmaz.
class LineDetailScreen extends ConsumerStatefulWidget {
  const LineDetailScreen({super.key, required this.code, this.city});

  final String code;

  /// Hat BAŞKA şehrin paketindeyse o şehir. Null = aktif şehir.
  ///
  /// Arama bütün kurulu paketlerde yapıldığı için kullanıcı Kocaeli'deyken
  /// İstanbul hattına bakabiliyor; bunun için aktif şehri DEĞİŞTİRMİYORUZ —
  /// sorgular doğrudan o şehrin veritabanına gidiyor.
  final TransitCity? city;

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

  /// Ham durak kimliği -> o durakta bulunan araç sayısı.
  ///
  /// İETT filo servisi her araç için `yakinDurakKodu` veriyor; seçili YÖNÜN
  /// araçları sayılır (gidiş/dönüş karışmasın diye `guzergahkodu` süzülür).
  Map<String, int> _busesAtStop = const {};

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
    final v = await TransitDb.instance
        .directionsForCode(widget.code, cityId: widget.city?.id);
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
    unawaited(_loadLiveBuses());
  }

  Future<void> _loadSelected() async {
    final id = _selectedId;
    if (id == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    final line =
        await TransitDb.instance.buildLine(id, cityId: widget.city?.id);
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
    _busesAtStop = const {};        // yön değişti: eski konumlar geçersiz
    _loadSelected();
    _loadLiveBuses();
  }

  /// Hattın canlı araçlarını çekip hangi durakta olduklarını işaretle.
  ///
  /// Yalnızca canlı filo servisi olan şehirde çalışır. Seçili yönün araçları
  /// sayılır: aynı hattın karşı yönündeki otobüsü "bu durakta" göstermek
  /// kullanıcıyı yanlış otobüse bindirirdi.
  Future<void> _loadLiveBuses() async {
    if (!_lineCity.hasLiveBus) return;
    final id = _selectedId;
    if (id == null) return;
    final isGidis = id.endsWith('_G');
    try {
      final vehicles = await LiveBusService.instance.vehicles(widget.code);
      if (!mounted || _selectedId != id) return;
      final counts = <String, int>{};
      for (final v in vehicles) {
        final code = v.nearestStopCode.trim();
        if (code.isEmpty) continue;
        // Yönü belirsiz araç (depar/boş güzergâh kodu) sayılmaz: yanlış
        // yöne yazmaktansa hiç yazmamak doğru.
        final known = v.routeCode.contains('_G_') || v.routeCode.contains('_D_');
        if (!known || v.isGidis != isGidis) continue;
        counts[code] = (counts[code] ?? 0) + 1;
      }
      setState(() => _busesAtStop = counts);
    } catch (_) {
      // Canlı veri yoksa liste sade hâliyle çalışır.
    }
  }

  bool get _selectedIsDepar => _depar.any((d) => d.id == _selectedId);

  /// HATTIN ait olduğu şehir — aktif şehir DEĞİL.
  ///
  /// Canlı konum bu şehre göre belirlenir: Kocaeli'deyken İstanbul hattına
  /// bakan kullanıcıdan canlı takibi saklamak yanlıştı (İETT servisi hattın
  /// şehrine bağlı, kullanıcının bulunduğu şehre değil).
  TransitCity get _lineCity => widget.city ?? ref.read(activeCityProvider);

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
            _actions(text),
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
                        final raw = stop.id.startsWith(kBusPrefix)
                            ? stop.id.substring(kBusPrefix.length)
                            : stop.id;
                        return _StopRow(
                          name: stop.name,
                          index: q.isEmpty ? i + 1 : null,
                          isFirst: q.isEmpty && i == 0,
                          isLast: isLast,
                          color: lineColorOf(
                              line?.color ?? '', line?.type ?? LineType.bus),
                          busCount: _busesAtStop[raw] ?? 0,
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

  /// Üst çubuk: hat rozeti (türüne göre renk) + hattın gittiği yön.
  Widget _header(TextTheme text) {
    final line = _line;
    final type = line?.type ?? LineType.bus;
    // Hattın kendi resmi rengi varsa onu kullan (Kocaeli beslemesi veriyor).
    final color = lineColorOf(line?.color ?? '', type);
    return Padding(
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
              color: color.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(lineTypeIcon(type), size: 18, color: color),
                const SizedBox(width: 8),
                Text(widget.code,
                    style: text.titleMedium?.copyWith(
                        color: color, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                    // İşletmeci varsa yaz: belediye otobüsü ile minibüs
                    // kooperatifi kullanıcı için farklı deneyim.
                    (line?.operator.isNotEmpty ?? false)
                        ? '${type.label} · ${line!.operator}'
                        : type.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                if (line != null)
                  Text(line.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          text.labelSmall?.copyWith(color: color)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Hattı haritada görme ve canlı araçları izleme kısayolları.
  ///
  /// Eskiden yalnızca üst çubukta küçük bir simge vardı; kullanıcı fark
  /// etmiyordu. "Rotayı görüntüle" her hatta çıkar, "Canlı konum" yalnızca
  /// canlı filo servisi olan şehirlerde (İETT açık servis veriyor, Kocaeli
  /// vermiyor) — olmayan özelliği düğme yapmak ölü dokunuş olurdu.
  Widget _actions(TextTheme text) {
    final line = _line;
    if (line == null) return const SizedBox.shrink();
    // Hattın şehri canlı filo servisi veriyorsa göster — kullanıcının hangi
    // şehirde olduğu belirleyici değil.
    final TransitCity lineCity = widget.city ?? ref.watch(activeCityProvider);
    final hasLive = lineCity.hasLiveBus &&
        (line.type == LineType.bus || line.type == LineType.metrobus);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
      child: Row(
        children: [
          Expanded(
            child: _ActionButton(
              icon: Icons.route_rounded,
              label: 'Rotayı görüntüle',
              filled: true,
              onTap: () {
                Haptics.light();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) =>
                        RouteMapScreen(line: line, city: widget.city)));
              },
            ),
          ),
          if (hasLive) ...[
            const SizedBox(width: 10),
            Expanded(
              child: _ActionButton(
                icon: Icons.my_location_rounded,
                label: 'Canlı konum',
                filled: false,
                onTap: () {
                  Haptics.light();
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                        LiveBusScreen(line: line, city: widget.city)));
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

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
/// Hat sayfasındaki birincil eylem düğmesi.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.filled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = filled ? Colors.white : VigilantColors.onSurface;
    return Material(
      color: filled
          ? VigilantColors.primary
          : VigilantColors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: fg, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
    required this.isFirst,
    required this.isLast,
    required this.color,
    required this.busCount,
    required this.onTap,
  });

  final String name;
  final int? index;
  final bool isFirst;
  final bool isLast;
  final Color color;

  /// Bu durakta bulunan CANLI araç sayısı (0 = bilgi yok/araç yok).
  final int busCount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final here = busCount > 0;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Zaman çizelgesi: duraklar arası bağlantı çizgisi. Düz numaralı
            // liste hattın SIRALI olduğunu anlatmıyordu.
            SizedBox(
              width: 34,
              child: Column(
                children: [
                  Expanded(
                    child: Container(
                      width: 2,
                      color: isFirst
                          ? Colors.transparent
                          : color.withValues(alpha: 0.35),
                    ),
                  ),
                  Container(
                    width: here ? 20 : 14,
                    height: here ? 20 : 14,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: here ? color : VigilantColors.background,
                      border: Border.all(
                          color: color.withValues(alpha: here ? 1 : 0.7),
                          width: 2.5),
                    ),
                    child: isLast
                        ? Icon(Icons.flag_rounded,
                            size: 9,
                            color: here ? Colors.white : color)
                        : null,
                  ),
                  Expanded(
                    child: Container(
                      width: 2,
                      color: isLast
                          ? Colors.transparent
                          : color.withValues(alpha: 0.35),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 11),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (index != null) ...[
                          Text('$index',
                              style: text.labelSmall?.copyWith(
                                  color: VigilantColors.onSurfaceVariant,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Text(name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium?.copyWith(
                                  fontWeight:
                                      here ? FontWeight.w700 : FontWeight.w400)),
                        ),
                      ],
                    ),
                    // CANLI: bu durakta şu an bekleyen/duran araç.
                    if (here)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(
                          children: [
                            Icon(Icons.directions_bus_filled_rounded,
                                size: 13, color: color),
                            const SizedBox(width: 5),
                            Text(
                                busCount == 1
                                    ? 'Şu an bu durakta'
                                    : 'Şu an $busCount otobüs burada',
                                style: text.labelSmall?.copyWith(
                                    color: color, fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.alarm_add_rounded,
                size: 20, color: VigilantColors.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
