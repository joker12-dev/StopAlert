import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models.dart';
import '../data/recent_search.dart';
import '../data/transit_city.dart';
import '../data/timetable.dart';
import '../data/transit_db.dart';
import '../services/bus_data_service.dart';
import '../engine/scheduled_vehicles.dart';
import '../services/iett_service.dart';
import '../services/live_bus_service.dart';
import '../services/timetable_service.dart';
import '../state/city_provider.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../util/haptics.dart';
import '../widgets/skeleton.dart';
import 'alarm_setup_screen.dart';
import 'line_announcements_screen.dart';
import 'live_bus_screen.dart';
import 'route_map_screen.dart';
import 'stop_lines_screen.dart';
import 'timetable_screen.dart';

/// Tek otobüs hattı sayfası (İETT tarzı): "MK13" → NORMAL gidiş/dönüş +
/// ayrı DEPAR güzergâhları. Kullanıcı güzergâhı/yönü seçer, ineceği durağa
/// dokununca alarm kurulur. Depar (garaj/özel sefer) normalle karışmaz.
class LineDetailScreen extends ConsumerStatefulWidget {
  const LineDetailScreen({
    super.key,
    required this.code,
    this.city,
    this.type,
  });

  final String code;

  /// Hattın TÜRÜ biliniyorsa geçilir.
  ///
  /// Aynı kod iki türde olabiliyor: İETT'de M5/M7/F2 kodlu OTOBÜS hatları
  /// var, aynı kodlu metro hatları da aynı pakette. Tür verilmezse sayfa
  /// ikisini karıştırırdı.
  final LineType? type;

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

  /// Yukarıdaki sayılar tarifeden mi üretildi (ray hatları).
  bool _busesScheduled = false;

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

  /// RAY/VAPUR hatları indirilen SQLite paketinde DEĞİL, ayrı listede
  /// (lines.json). Bu sayfa yalnızca pakete bakıyordu ve Marmaray/metro/vapur
  /// açıldığında durak listesi bomboş geliyordu.
  TransitLine? _railLine;

  /// Ray hattında yön: tek bir durak dizisi var, dönüş onun TERSİ.
  bool _railReversed = false;

  Future<void> _load() async {
    var v = await TransitDb.instance.directionsForCode(widget.code,
        cityId: widget.city?.id, type: widget.type?.name);
    // BOŞ ÇIKTIYSA PAKETLERİ AÇIP BİR KEZ DAHA DENE.
    //
    // Başka şehrin paketi yalnızca arama yapıldığında açılıyordu. Uygulama
    // yeniden başlatılıp "son aramalar"dan doğrudan bir hatta girildiğinde o
    // paket kapalı oluyor ve sayfa bomboş açılıyordu — kullanıcı aynı hattın
    // bir önceki oturumda çalıştığını, şimdi çalışmadığını görüyordu.
    if (v.isEmpty) {
      await BusDataService.instance.openAllForLookup();
      if (!mounted) return;
      v = await TransitDb.instance.directionsForCode(widget.code,
          cityId: widget.city?.id, type: widget.type?.name);
      // Tür süzgeci kaydı eskiyse (tür değişmiş/eksik yazılmış) süzgeçsiz dene:
      // yanlış türle hiç sonuç bulamamaktansa doğru hattı açmak yeğdir.
      if (v.isEmpty && widget.type != null) {
        v = await TransitDb.instance
            .directionsForCode(widget.code, cityId: widget.city?.id);
      }
    }
    if (!mounted) return;

    if (v.isEmpty) {
      // Pakette yok: gömülü ray/vapur listesinde ara.
      final rail = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
      for (final l in rail) {
        if (l.code == widget.code) {
          _railLine = l;
          break;
        }
      }
      if (_railLine != null) {
        setState(() {
          _line = _railLine;
          _loading = false;
        });
        return;
      }
    }
    _gidis = _firstDir(v, 'G');
    _donus = _firstDir(v, 'D');
    _depar = [
      for (final x in v)
        if (x.depar) x
    ];
    // Yön etiketi olmayan normal varyant (nadiren): ilk normali gidiş say.
    if (_gidis == null && _donus == null) {
      final normal = [
        for (final x in v)
          if (!x.depar) x
      ];
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

  /// Ray hattında yönü ters çevir (paket hatlarında ayrı varyant vardır).
  void _toggleRailDirection() {
    final base = _railLine;
    if (base == null) return;
    Haptics.selection();
    setState(() {
      _railReversed = !_railReversed;
      _line = TransitLine(
        id: base.id,
        code: base.code,
        name: _railReversed
            ? base.name.split(' - ').reversed.join(' - ')
            : base.name,
        type: base.type,
        color: base.color,
        operator: base.operator,
        stops: _railReversed ? base.stops.reversed.toList() : base.stops,
        segmentSeconds: base.segmentSeconds == null
            ? null
            : (_railReversed
                ? base.segmentSeconds!.reversed.toList()
                : base.segmentSeconds),
      );
    });
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
    _busesAtStop = const {}; // yön değişti: eski konumlar geçersiz
    // SIRALI: ray yolunda araç konumu hattın TÜRÜNDEN ve duraklarından
    // üretiliyor; _line dolmadan çağırmak sessizce boş liste veriyordu.
    _loadSelected().then((_) => _loadLiveBuses());
  }

  /// Hattın araçlarını çekip hangi durakta olduklarını işaretle.
  ///
  /// Seçili yönün araçları sayılır: aynı hattın karşı yönündeki otobüsü "bu
  /// durakta" göstermek kullanıcıyı yanlış otobüse bindirirdi.
  ///
  /// RAY HATLARINDA konum tarifeden üretilir (bkz. `ScheduledVehicles`) —
  /// "ineceğin durağı seç" listesinde metro/Marmaray hiç işaretlenmiyordu.
  Future<void> _loadLiveBuses() async {
    final id = _selectedId;
    if (id == null) return;
    final line = _line;
    if (line == null) return;
    final rail =
        line.type != LineType.bus && line.type != LineType.metrobus;
    final isGidis = id.endsWith('_G');
    try {
      // CANLI YOL ŞEHİRDEN BAĞIMSIZ: İstanbul İETT, Kocaeli e-komobil (izinliyken).
      // Ray hatları tarifeden konumlanır.
      final vehicles = rail
          ? await _scheduledVehicles(line)
          : await LiveBusService.instance.vehicles(
              widget.code,
              city: _lineCity,
              lineId: id,
            );
      if (!mounted || _selectedId != id) return;
      final counts = <String, int>{};
      for (final v in vehicles) {
        // Yönü belirsiz araç (depar/boş güzergâh kodu) sayılmaz: yanlış
        // yöne yazmaktansa hiç yazmamak doğru.
        final known =
            v.routeCode.contains('_G_') || v.routeCode.contains('_D_');
        if (!known || v.isGidis != isGidis) continue;

        // DURAK KODU YOKSA KONUMDAN BUL. İETT her araç için yakınDurakKodu
        // veriyor; Kocaeli (e-komobil) ve tarifeden üretilen araçlar vermiyor.
        // O durumda aracın koordinatı hattın en yakın durağına eşlenir.
        var code = v.nearestStopCode.trim();
        if (code.isEmpty) {
          final near = _nearestStopCode(line, v);
          if (near == null) continue;
          code = near;
        }
        counts[code] = (counts[code] ?? 0) + 1;
      }
      setState(() {
        _busesAtStop = counts;
        _busesScheduled = rail;
      });
    } catch (_) {
      // Canlı veri yoksa liste sade hâliyle çalışır.
    }
  }

  /// Aracın koordinatına en yakın durağın HAM kimliği (yoksa null).
  ///
  /// Durak satırı ham kimlikle eşleştiğinden (`bus:` öneki ayıklanmış) burada
  /// da ham hâli döndürülür.
  String? _nearestStopCode(TransitLine line, BusVehicle v) {
    if (!v.lat.isFinite || !v.lon.isFinite) return null;
    double? best;
    String? bestId;
    for (final s in line.stops) {
      final dLat = (s.lat - v.lat).abs();
      final dLon = (s.lon - v.lon).abs();
      final d = dLat * dLat + dLon * dLon; // karşılaştırma için karesel yeter
      if (best == null || d < best) {
        best = d;
        bestId =
            s.id.startsWith(kBusPrefix) ? s.id.substring(kBusPrefix.length) : s.id;
      }
    }
    return bestId;
  }

  /// Tarifeden üretilen araçlar — ray hatlarında canlı yayının yerini alır.
  Future<List<BusVehicle>> _scheduledVehicles(TransitLine line) async {
    if (!_lineCity.hasTimetable) return const [];
    final table = await TimetableService.instance
        .forLine(line.code, city: _lineCity, type: line.type);
    if (table.isEmpty) return const [];
    final rows = table.forDay(DayType.forDate(DateTime.now()),
        outbound: line.id.contains('_G'));
    if (rows.isEmpty) return const [];
    return ScheduledVehicles.forLine(line: line, departures: rows);
  }

  bool get _selectedIsDepar => _depar.any((d) => d.id == _selectedId);

  /// HATTIN ait olduğu şehir — aktif şehir DEĞİL.
  ///
  /// Canlı konum bu şehre göre belirlenir: Kocaeli'deyken İstanbul hattına
  /// bakan kullanıcıdan canlı takibi saklamak yanlıştı (İETT servisi hattın
  /// şehrine bağlı, kullanıcının bulunduğu şehre değil).
  TransitCity get _lineCity => widget.city ?? ref.read(activeCityProvider);

  /// Durak künyesi sayfasını aç (yaklaşan otobüsler + geçen hatlar).
  Future<void> _openStopInfo(Stop stop) async {
    Haptics.light();
    // SORGU BAŞARISIZ OLSA DA SAYFA AÇILIR.
    //
    // Ray hatları eski paketlerde ayrı listeden (lines.json) geliyor ve o
    // durakların kimlikleri paket biçiminde değil; `linesForStop` onlarda
    // hata veriyor ve "i" tuşu hiçbir şey yapmıyormuş gibi görünüyordu.
    // Durak künyesi hat listesi olmadan da anlamlı: ad, yön, konum.
    var lines = const <TransitLineBrief>[];
    try {
      if (isBusId(stop.id)) {
        lines = await TransitDb.instance
            .linesForStop(stop.id, cityId: widget.city?.id);
      } else {
        final rail =
            ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
        lines = [
          for (final l in rail)
            if (l.stops.any((x) => x.id == stop.id))
              TransitLineBrief(
                  id: l.id, code: l.code, name: l.name, type: l.type),
        ];
      }
    } catch (_) {
      // Hat listesi çözülemedi; künye yine açılır.
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          StopLinesScreen(stop: stop, lines: lines, city: widget.city),
    ));
  }

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
            _timetableAction(text),
            _announcementsAction(text),
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
                      // RAY/VAPUR: tek durak dizisi var, yön onun tersi.
                      if (_railLine case final rail?)
                        Row(
                          children: [
                            Expanded(
                              child: _DirTab(
                                label: 'Gidiş',
                                sub: rail.name,
                                selected: !_railReversed,
                                onTap: () {
                                  if (_railReversed) _toggleRailDirection();
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _DirTab(
                                label: 'Dönüş',
                                sub:
                                    rail.name.split(' - ').reversed.join(' - '),
                                selected: _railReversed,
                                onTap: () {
                                  if (!_railReversed) _toggleRailDirection();
                                },
                              ),
                            ),
                          ],
                        ),
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
                      padding: EdgeInsets.fromLTRB(
                          20, 0, 20, AppInsets.pageBottom(context)),
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
                          scheduled: _busesScheduled,
                          icon: lineTypeIcon(line?.type ?? LineType.bus),
                          onTap: () => _pickTarget(stop),
                          onInfo: () => _openStopInfo(stop),
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
                    style: text.titleMedium
                        ?.copyWith(color: color, fontWeight: FontWeight.w800)),
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
                      style: text.labelSmall?.copyWith(color: color)),
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
    // RAY HATLARINDA DA AÇILIR: konum canlı değil, tarifeden üretiliyor
    // (bkz. `ScheduledVehicles`). Ekran bunu açıkça yazıyor. Ölçüt, hattın
    // gösterilecek bir konumu olup olmadığı — canlı yayın olup olmadığı değil.
    final rubber = line.type == LineType.bus || line.type == LineType.metrobus;
    final hasLive = rubber ? lineCity.hasLiveBus : lineCity.hasTimetable;
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

  /// Bu hattın DUYURULARI (sefer iptali, güzergâh değişikliği).
  ///
  /// Yalnızca İETT hatlarında: duyuru servisi İstanbul'un lastikli hatları
  /// için yayınlanıyor, metro/Marmaray ve Kocaeli için karşılığı yok. Butonu
  /// her yerde göstermek her seferinde boş sayfa açardı.
  Widget _announcementsAction(TextTheme text) {
    final line = _line;
    if (line == null) return const SizedBox.shrink();
    final TransitCity lineCity = widget.city ?? ref.watch(activeCityProvider);
    final rubber = line.type == LineType.bus || line.type == LineType.metrobus;
    if (!lineCity.hasAnnouncements || !rubber) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: _ActionButton(
        icon: Icons.campaign_outlined,
        label: 'Hat duyuruları',
        filled: false,
        onTap: () {
          Haptics.light();
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => LineAnnouncementsScreen(
              lineCode: line.code,
              lineName: line.name,
            ),
          ));
        },
      ),
    );
  }

  /// Sefer saatleri kısayolu — yalnızca kalkış takvimi servisi olan şehirde
  /// ve yalnızca lastikli hatlarda (İETT bu servisi metro/vapur için vermiyor).
  Widget _timetableAction(TextTheme text) {
    final line = _line;
    if (line == null) return const SizedBox.shrink();
    final TransitCity lineCity = widget.city ?? ref.watch(activeCityProvider);
    // TÜR KISITI YOK: İstanbul'da servis yalnızca lastikli hatlar için anlamlı
    // olsa da, Kocaeli'de saatler pakette duruyor ve tramvay/vapur için de
    // var. Veri yoksa ekran zaten "saat bilgisi yok" diyor.
    if (!lineCity.hasTimetable) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: _ActionButton(
        icon: Icons.schedule_rounded,
        label: 'Sefer saatleri',
        filled: false,
        onTap: () {
          Haptics.light();
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => TimetableScreen(
              lineCode: line.code,
              lineName: line.name,
              city: lineCity,
              type: line.type,
              outboundLabel: _terminalLabel(_gidis?.name) ?? 'Gidiş',
              inboundLabel: _terminalLabel(_donus?.name) ?? 'Dönüş',
            ),
          ));
        },
      ),
    );
  }

  /// "A - B" biçimindeki varyant adından VARIŞ ucunu alır: sekme etiketine
  /// tam ad sığmıyor, kullanıcıya asıl gereken nereye gittiği.
  static String? _terminalLabel(String? variantName) {
    final n = variantName?.trim();
    if (n == null || n.isEmpty) return null;
    final i = n.lastIndexOf(' - ');
    final label = i < 0 ? n : n.substring(i + 3).trim();
    return label.isEmpty ? null : label;
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
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: VigilantColors.tertiaryContainer)),
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
          prefixIcon:
              const Icon(Icons.search, color: VigilantColors.onSurfaceVariant),
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
      color:
          filled ? VigilantColors.primary : VigilantColors.surfaceContainerHigh,
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
                    style: Theme.of(context)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: fg, fontWeight: FontWeight.w700)),
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
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
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
    required this.scheduled,
    required this.icon,
    required this.onTap,
    required this.onInfo,
  });

  final String name;
  final int? index;
  final bool isFirst;
  final bool isLast;
  final Color color;

  /// Bu durakta bulunan araç sayısı (0 = bilgi yok/araç yok).
  final int busCount;

  /// Sayı TARİFEDEN üretildiyse dil değişir: "şu an" demek yanlış olurdu.
  final bool scheduled;

  /// Hattın türüne göre simge — metro satırında otobüs simgesi yanlıştı.
  final IconData icon;
  final VoidCallback onTap;

  /// Durak künyesine git (yaklaşan otobüsler, geçen hatlar).
  final VoidCallback onInfo;

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
                            size: 9, color: here ? Colors.white : color)
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
                                  fontWeight: here
                                      ? FontWeight.w700
                                      : FontWeight.w400)),
                        ),
                      ],
                    ),
                    // CANLI: bu durakta şu an bekleyen/duran araç.
                    if (here)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(
                          children: [
                            Icon(icon, size: 13, color: color),
                            const SizedBox(width: 5),
                            Text(
                                scheduled
                                    ? (busCount == 1
                                        ? 'Tarifeye göre burada'
                                        : 'Tarifeye göre $busCount araç burada')
                                    : (busCount == 1
                                        ? 'Şu an bu durakta'
                                        : 'Şu an $busCount araç burada'),
                                style: text.labelSmall?.copyWith(
                                    color: color, fontWeight: FontWeight.w700)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            // Durak künyesi: yaklaşan otobüsler ve duraktan geçen
            // öteki hatlar. Alarm kurmadan ÖNCE bakmak isteyen için.
            IconButton(
              onPressed: onInfo,
              visualDensity: VisualDensity.compact,
              tooltip: 'Durak bilgisi',
              icon: const Icon(Icons.info_outline_rounded,
                  size: 20, color: VigilantColors.onSurfaceVariant),
            ),
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Icon(Icons.alarm_add_rounded,
                  size: 20, color: VigilantColors.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
