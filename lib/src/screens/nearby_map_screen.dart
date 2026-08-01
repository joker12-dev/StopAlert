import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../data/models.dart';
import '../data/transit_db.dart';
import '../services/routing_service.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/map_style.dart';
import 'alarm_setup_screen.dart';
import 'stop_lines_screen.dart';

/// Yakındaki Duraklar HARİTASI: üstte harita (yakın duraklar işaretli),
/// altta yüksekliği ayarlanabilen panel (en yakından uzağa liste). Bir durağa
/// dokununca harita o durağa zoomlanır ve konumundan durağa YÜRÜME ROTASI
/// (OSRM, yollardan) çizilir — kullanıcı nereden gideceğini görür.
class NearbyMapScreen extends ConsumerStatefulWidget {
  const NearbyMapScreen({super.key, this.focusStop});

  /// Verilirse harita bu durağa odaklanır ve durak seçili açılır
  /// (durak sayfasındaki "Haritada göster" akışı).
  final Stop? focusStop;

  @override
  ConsumerState<NearbyMapScreen> createState() => _NearbyMapScreenState();
}

class _NearbyMapScreenState extends ConsumerState<NearbyMapScreen> {
  final _map = MapController();
  bool _mapReady = false;

  MapStop? _selected;
  List<LatLng> _walk = const [];
  bool _walkLoading = false;

  /// Arama noktası çevresindeki duraklar + yükleme durumu.
  List<MapStop> _visible = const [];
  bool _loadingStops = false;
  Timer? _debounce;

  /// TURUNCU arama noktası: haritanın merkezi. Haritayı gezdirdikçe taşınır ve
  /// çevresindeki [_radius] metre içindeki duraklar listelenir (mavi nokta =
  /// kullanıcının gerçek konumu, o sabittir).
  LatLng? _probe;

  /// Arama yarıçapı (metre) — kullanıcı çipten değiştirir.
  double _radius = 500;
  static const _radiusOptions = [250.0, 500.0, 1000.0];

  // Sürüklenebilir panel (Alarm Kur ekranındaki gibi).
  static const _minFraction = 0.28;
  static const _maxFraction = 0.75;
  double _panelFraction = 0.42;
  double _availableHeight = 0;

  LatLng? get _userLoc {
    final p = ref.read(currentLocationProvider).valueOrNull?.point;
    return p == null ? null : LatLng(p.latitude, p.longitude);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// Harita her oynadığında değil, durduktan kısa süre sonra sorgula.
  void _scheduleReload() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _reloadVisible);
  }

  /// TURUNCU arama noktasının (harita merkezi) [_radius] metre çevresindeki
  /// durakları yükle. Tüm şehri belleğe almak yerine yalnızca bu daireyi
  /// sorgular (otobüs = indeksli SQLite bbox + daire filtresi).
  Future<void> _reloadVisible() async {
    if (!_mapReady || !mounted) return;
    final probe = _map.camera.center;
    setState(() {
      _probe = probe;
      _loadingStops = true;
    });

    const distance = Distance();
    final r = _radius;
    final out = <MapStop>[];

    // Ray/vapur — bellekteki hatlar; daire içi, aynı adlı durak tekilleştirilir.
    final lines = ref.read(linesProvider).valueOrNull ?? const <TransitLine>[];
    final rail = <String, MapStop>{};
    for (final line in lines) {
      for (final s in line.stops) {
        if (s.lat == 0 && s.lon == 0) continue;
        final d = distance.as(LengthUnit.Meter, probe, LatLng(s.lat, s.lon));
        if (d > r) continue;
        final key = s.name.toLowerCase();
        final cur = rail[key];
        if (cur == null || d < cur.meters) {
          rail[key] = MapStop(stop: s, meters: d, line: line);
        }
      }
    }
    out.addAll(rail.values);

    // Otobüs — daireyi çevreleyen dikdörtgeni sorgula, sonra daireye kırp.
    if (TransitDb.instance.isReady) {
      final dLat = r / 111000.0;
      final cosLat = math.cos(probe.latitude * math.pi / 180).abs();
      final dLon = r / (111000.0 * (cosLat < 0.01 ? 0.01 : cosLat));
      final busStops = await TransitDb.instance.stopsInBounds(
        probe.latitude - dLat,
        probe.latitude + dLat,
        probe.longitude - dLon,
        probe.longitude + dLon,
        limit: 300,
      );
      final bus = <String, MapStop>{};
      for (final s in busStops) {
        final d = distance.as(LengthUnit.Meter, probe, LatLng(s.lat, s.lon));
        if (d > r) continue;
        final key = '${s.name.toLowerCase()}|${s.direction.toLowerCase()}';
        final cur = bus[key];
        if (cur == null || d < cur.meters) {
          bus[key] = MapStop(stop: s, meters: d, line: null);
        }
      }
      out.addAll(bus.values);
    }

    out.sort((a, b) => a.meters.compareTo(b.meters));
    if (!mounted) return;
    setState(() {
      _visible = out.take(200).toList();
      _loadingStops = false;
    });
  }

  void _setRadius(double r) {
    if (_radius == r) return;
    Haptics.selection();
    setState(() => _radius = r);
    _reloadVisible();
  }

  /// Kullanıcının konumu kapsam dışındaysa (ör. Kocaeli) en yakın durağa git.
  Future<void> _goToNearest() async {
    final nearest = ref.read(nearbyMapProvider).valueOrNull;
    if (nearest == null || nearest.isEmpty || !_mapReady) return;
    Haptics.light();
    final s = nearest.first.stop;
    _map.move(LatLng(s.lat, s.lon), 15);
    await _reloadVisible();
  }

  Future<void> _selectStop(MapStop m) async {
    Haptics.light();
    setState(() {
      _selected = m;
      _walk = const [];
      _walkLoading = true;
    });
    final target = LatLng(m.stop.lat, m.stop.lon);
    if (_mapReady) {
      // Durak + konumu birlikte sığdır (yolu görebilmek için).
      final user = _userLoc;
      if (user != null) {
        _map.fitCamera(CameraFit.bounds(
          bounds: LatLngBounds.fromPoints([user, target]),
          padding: const EdgeInsets.fromLTRB(60, 80, 60, 40),
        ));
      } else {
        _map.move(target, 16);
      }
    }
    // OSRM yürüme rotası (konum → durak). Ağ yoksa boş (düz çizgi çizilmez).
    final user = _userLoc;
    List<LatLng> walk = const [];
    if (user != null) walk = await RoutingService.instance.walk(user, target);
    if (!mounted) return;
    setState(() {
      _walk = walk;
      _walkLoading = false;
    });
  }

  void _startAlarm(MapStop m) {
    Haptics.light();
    final line = m.line;
    if (line != null) {
      // Ray/vapur: hat belli → doğrudan Alarm Kur (durak = hedef).
      ref.read(journeyDraftProvider.notifier)
        ..reset()
        ..selectLine(line)
        ..selectTargetStop(m.stop.id);
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            AlarmSetupScreen(stopName: m.stop.name, lineLabel: line.code),
      ));
    } else {
      // Otobüs: bu duraktan geçen hatları seçtir.
      _openBusStop(m.stop);
    }
  }

  Future<void> _openBusStop(Stop stop) async {
    final lines = await TransitDb.instance.linesForStop(stop.id);
    if (!mounted) return;
    if (lines.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            const SnackBar(content: Text('Bu duraktan geçen hat bulunamadı.')));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => StopLinesScreen(stop: stop, lines: lines),
    ));
  }

  String _fmt(double m) => m >= 1000
      ? '${(m / 1000).toStringAsFixed(1).replaceAll('.', ',')} km'
      : '${m.round()} m';

  bool _isSelected(MapStop m) => _selected?.stop.id == m.stop.id;

  /// Çizilecek işaretler: görünen alandakiler + (listede yoksa) seçili durak.
  List<MapStop> _markerStops(List<MapStop> visible) {
    final sel = _selected;
    if (sel == null || visible.any((m) => m.stop.id == sel.stop.id)) {
      return visible;
    }
    return [...visible, sel];
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // Panel + markerlar GÖRÜNEN alandan gelir (viewport/chunk yükleme).
    final stops = _visible;
    // Yakın duraklar yalnızca "en yakına git" kısayolu için okunur.
    final nearest = ref.watch(nearbyMapProvider).valueOrNull ?? const <MapStop>[];
    final user = _userLoc;
    final center = user ??
        (nearest.isNotEmpty
            ? LatLng(nearest.first.stop.lat, nearest.first.stop.lon)
            : const LatLng(41.0082, 28.9784));

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          _availableHeight = constraints.maxHeight;
          final panelH = _availableHeight * _panelFraction;
          return Stack(
            children: [
              // Harita
              Positioned.fill(
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: center,
                    initialZoom: 15,
                    minZoom: 3,
                    maxZoom: 18,
                    backgroundColor: VigilantColors.surfaceContainerLowest,
                    onMapReady: () {
                      _mapReady = true;
                      final focus = widget.focusStop;
                      if (focus != null) {
                        // Durak sayfasından gelindi: o durağa odaklan + seç.
                        final target = LatLng(focus.lat, focus.lon);
                        _map.move(target, 16);
                        final m = user == null
                            ? 0.0
                            : const Distance()
                                .as(LengthUnit.Meter, user, target);
                        _selectStop(MapStop(stop: focus, meters: m));
                      } else if (user != null) {
                        _map.move(user, 15);
                      }
                      _reloadVisible(); // ilk parçayı yükle
                    },
                    // Harita her kaydırma/zoom sonrası görünen parçayı tazeler.
                    onPositionChanged: (_, __) => _scheduleReload(),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://{s}.basemaps.cartocdn.com/${AppMapStyle.tileVariant}/{z}/{x}/{y}{r}.png',
                      subdomains: const ['a', 'b', 'c', 'd'],
                      userAgentPackageName: 'com.originstudios.stopalert',
                      retinaMode: RetinaMode.isHighDensity(context),
                    ),
                    // TURUNCU arama dairesi (haritayı gezdirdikçe taşınır)
                    if (_probe case final p?)
                      CircleLayer(circles: [
                        CircleMarker(
                          point: p,
                          radius: _radius,
                          useRadiusInMeter: true,
                          color: VigilantColors.tertiaryContainer
                              .withValues(alpha: 0.12),
                          borderColor: VigilantColors.tertiaryContainer
                              .withValues(alpha: 0.8),
                          borderStrokeWidth: 2,
                        ),
                      ]),
                    // Yürüme rotası (yollardan)
                    if (_walk.length >= 2)
                      PolylineLayer(polylines: [
                        Polyline(
                          points: _walk,
                          strokeWidth: 5,
                          color: VigilantColors.accentBlue,
                          borderStrokeWidth: 1.5,
                          borderColor: Colors.white.withValues(alpha: 0.4),
                        ),
                      ]),
                    // Durak işaretleri (yalnızca görünen alandakiler). Seçili
                    // durak listede olmasa da (kaydırıldıysa) işaretli kalır.
                    MarkerLayer(
                      markers: [
                        for (final m in _markerStops(stops))
                          Marker(
                            point: LatLng(m.stop.lat, m.stop.lon),
                            width: _isSelected(m) ? 38 : 18,
                            height: _isSelected(m) ? 38 : 18,
                            child: GestureDetector(
                              onTap: () => _selectStop(m),
                              child: _StopMarker(
                                  selected: _isSelected(m), isBus: m.isBus),
                            ),
                          ),
                      ],
                    ),
                    if (user != null)
                      MarkerLayer(markers: [
                        Marker(
                          point: user,
                          width: 26,
                          height: 26,
                          child: const _UserDot(),
                        ),
                      ]),
                    // Turuncu arama noktası (dairenin merkezi) — en üstte
                    if (_probe case final p?)
                      MarkerLayer(markers: [
                        Marker(
                          point: p,
                          width: 22,
                          height: 22,
                          child: const _ProbeDot(),
                        ),
                      ]),
                  ],
                ),
              ),
              // Üst çubuk — Positioned (Stack'in tüm çocukları konumlanmalı ki
              // Stack tüm ekranı doldursun; aksi halde SafeArea'ya küçülür).
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        _RoundBtn(
                            icon: Icons.arrow_back,
                            onTap: () => Navigator.of(context).pop()),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: VigilantColors.surfaceContainer
                                .withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text('Yakındaki Duraklar',
                              style: text.labelLarge
                                  ?.copyWith(fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // Alt panel
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: panelH,
                child: _panel(text, stops, nearest.isNotEmpty),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _panel(TextTheme text, List<MapStop> stops, bool hasNearest) {
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerLow,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 28,
              offset: const Offset(0, -6)),
        ],
      ),
      child: Column(
        children: [
          // Sürükleme tutamağı
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) {
              if (_availableHeight == 0) return;
              setState(() {
                _panelFraction =
                    (_panelFraction - d.delta.dy / _availableHeight)
                        .clamp(_minFraction, _maxFraction);
              });
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: VigilantColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
          // Seçili durak eylem çubuğu
          if (_selected case final sel?) _selectedBar(text, sel),
          // Arama noktası özeti + yarıçap seçimi
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: VigilantColors.tertiaryContainer,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Bu noktanın çevresinde ${stops.length} durak',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                ),
                if (_loadingStops)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: VigilantColors.primary),
                  ),
              ],
            ),
          ),
          // Yarıçap çipleri
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
            child: Row(
              children: [
                for (final r in _radiusOptions) ...[
                  _RadiusChip(
                    label: r >= 1000
                        ? '${(r / 1000).toStringAsFixed(0)} km'
                        : '${r.round()} m',
                    selected: _radius == r,
                    onTap: () => _setRadius(r),
                  ),
                  const SizedBox(width: 8),
                ],
                const Spacer(),
                Text('haritayı gezdir',
                    style: text.labelSmall
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
              ],
            ),
          ),
          Expanded(
            child: _loadingStops && stops.isEmpty
                ? const Center(
                    child: CircularProgressIndicator(
                        color: VigilantColors.primary))
                : stops.isEmpty
                    ? _empty(text, hasNearest)
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: stops.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final m = stops[i];
                          return _StopTile(
                            m: m,
                            distanceText: _fmt(m.meters),
                            selected: _isSelected(m),
                            onTap: () => _selectStop(m),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _selectedBar(TextTheme text, MapStop sel) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: VigilantColors.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: VigilantColors.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(sel.stop.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Row(
                  children: [
                    const Icon(Icons.directions_walk,
                        size: 14, color: VigilantColors.accentBlue),
                    const SizedBox(width: 4),
                    Text(
                        _walkLoading
                            ? 'Yol çiziliyor…'
                            : (_walk.length >= 2
                                ? '${_fmt(sel.meters)} · yürüme rotası çizildi'
                                : _fmt(sel.meters)),
                        style: text.labelMedium?.copyWith(
                            color: VigilantColors.onSurfaceVariant)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: VigilantColors.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () => _startAlarm(sel),
            child: const Text('Alarm Kur'),
          ),
        ],
      ),
    );
  }

  /// Boş durum — görünen alanda durak yok. Çok uzaktaysa "yakınlaş", kapsam
  /// dışındaysa "en yakın durağa git" kısayolu sunar.
  Widget _empty(TextTheme text, bool hasNearest) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.explore_off_rounded,
                size: 34, color: VigilantColors.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'Turuncu noktanın çevresinde durak yok. Haritayı gezdir, '
              'yarıçapı büyüt ya da en yakın durağa git.',
              textAlign: TextAlign.center,
              style: text.bodyMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
            if (hasNearest) ...[
              const SizedBox(height: 14),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: VigilantColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _goToNearest,
                icon: const Icon(Icons.near_me_rounded, size: 18),
                label: const Text('En yakın durağa git'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StopTile extends StatelessWidget {
  const _StopTile({
    required this.m,
    required this.distanceText,
    required this.selected,
    required this.onTap,
  });

  final MapStop m;
  final String distanceText;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final sub = m.isBus
        ? (m.stop.direction.isNotEmpty
            ? 'Otobüs · ${m.stop.direction}'
            : 'Otobüs durağı')
        : '${m.line!.code} · ${m.line!.type.label}';
    return Material(
      color: selected
          ? VigilantColors.primary.withValues(alpha: 0.12)
          : VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (m.isBus
                          ? VigilantColors.primary
                          : lineTypeColor(m.line!.type))
                      .withValues(alpha: 0.15),
                ),
                child: Icon(
                    m.isBus
                        ? Icons.directions_bus_filled_rounded
                        : lineTypeIcon(m.line!.type),
                    size: 20,
                    color: m.isBus
                        ? VigilantColors.primary
                        : lineTypeColor(m.line!.type)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.stop.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.labelMedium?.copyWith(
                            color: VigilantColors.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(distanceText,
                      style: text.labelLarge?.copyWith(
                          color: VigilantColors.primary,
                          fontWeight: FontWeight.w700)),
                  const Icon(Icons.chevron_right,
                      size: 18, color: VigilantColors.onSurfaceVariant),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StopMarker extends StatelessWidget {
  const _StopMarker({required this.selected, required this.isBus});

  final bool selected;
  final bool isBus;

  @override
  Widget build(BuildContext context) {
    final color = isBus ? VigilantColors.primary : VigilantColors.secondary;
    if (selected) {
      return Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: [
            BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 12),
          ],
        ),
        child: Icon(
            isBus
                ? Icons.directions_bus_filled_rounded
                : Icons.location_on,
            color: Colors.white,
            size: 20),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.background,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 2.5),
      ),
    );
  }
}

/// Arama yarıçapı çipi (250 m / 500 m / 1 km).
class _RadiusChip extends StatelessWidget {
  const _RadiusChip(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? VigilantColors.tertiaryContainer.withValues(alpha: 0.18)
              : VigilantColors.surfaceContainer,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? VigilantColors.tertiaryContainer
                : VigilantColors.surfaceVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Text(label,
            style: text.labelMedium?.copyWith(
              color: selected
                  ? VigilantColors.tertiaryContainer
                  : VigilantColors.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            )),
      ),
    );
  }
}

/// Turuncu arama noktası — haritanın merkezinde durur, harita gezdirildikçe
/// taşınır; çevresindeki daire içindeki duraklar listelenir.
class _ProbeDot extends StatelessWidget {
  const _ProbeDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.tertiaryContainer,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
              color: VigilantColors.tertiaryContainer.withValues(alpha: 0.7),
              blurRadius: 10),
        ],
      ),
    );
  }
}

class _UserDot extends StatelessWidget {
  const _UserDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.accentBlue,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
              color: VigilantColors.accentBlue.withValues(alpha: 0.7),
              blurRadius: 10),
        ],
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: VigilantColors.surfaceContainer.withValues(alpha: 0.9),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(icon, color: VigilantColors.onSurface, size: 20),
        ),
      ),
    );
  }
}
