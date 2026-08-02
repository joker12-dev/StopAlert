import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../data/models.dart';
import '../services/routing_service.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../util/map_style.dart';
import 'alarm_setup_screen.dart';

/// "Rotayı görüntüle" — bir hattın güzergâhı harita üzerinde.
///
/// Hat listesi metin olarak zaten var; burada kullanıcı nereden geçtiğini
/// GÖRÜR. Durak adları yakınlaşınca yazılır, durağa dokununca alarm kartı
/// açılır ve hat ZATEN belli olduğu için doğrudan Alarm Kur'a geçilir.
class RouteMapScreen extends ConsumerStatefulWidget {
  const RouteMapScreen({super.key, required this.line});

  final TransitLine line;

  @override
  ConsumerState<RouteMapScreen> createState() => _RouteMapScreenState();
}

class _RouteMapScreenState extends ConsumerState<RouteMapScreen> {
  final _map = MapController();
  bool _mapReady = false;

  /// Güzergâhın YOLLARA oturmuş hali (OSRM). Boşsa duraklar arası düz çizgi.
  List<LatLng> _road = const [];
  Stop? _selected;

  /// Durak adlarını yazmak için yakınlaşma eşiği — daha uzakta etiketler
  /// üst üste binip haritayı okunmaz yapıyor.
  static const _labelZoom = 14.5;
  double _zoom = 13;

  double get _arrowSpacing => _zoom >= 15.5
      ? 300
      : _zoom >= 14
          ? 600
          : 1200;

  // Oklar güzergâh + aralık değişmedikçe yeniden hesaplanmaz.
  List<Marker> _arrows = const [];
  double? _arrowsFor;
  int _arrowsRouteLen = -1;

  @override
  void initState() {
    super.initState();
    _loadRoad();
  }

  Future<void> _loadRoad() async {
    // OSRM yalnızca karayolu hatlarında anlamlı: ray kendi rayında, vapur
    // denizde gider ve yola oturtmak absürt bir çizgi üretir.
    if (widget.line.type != LineType.bus &&
        widget.line.type != LineType.metrobus) {
      return;
    }
    final pts = _stopPoints;
    if (pts.length < 2) return;
    final road = await RoutingService.instance.route(pts);
    if (mounted && road.length >= 2) setState(() => _road = road);
  }

  List<Stop> get _stops =>
      [for (final s in widget.line.stops) if (s.lat != 0 || s.lon != 0) s];

  List<LatLng> get _stopPoints =>
      [for (final s in _stops) LatLng(s.lat, s.lon)];

  List<LatLng> get _drawRoute => _road.length >= 2 ? _road : _stopPoints;

  void _fit() {
    final pts = _stopPoints;
    if (!_mapReady || pts.isEmpty) return;
    _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(pts),
      padding: const EdgeInsets.fromLTRB(40, 110, 40, 160),
    ));
  }

  /// Bu hattın bu durağına alarm kur. Hat zaten belli olduğu için ara adım yok.
  void _setAlarm(Stop stop) {
    Haptics.light();
    ref.read(journeyDraftProvider.notifier)
      ..reset()
      ..selectLine(widget.line)
      ..selectTargetStop(stop.id);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AlarmSetupScreen(
          stopName: stop.name, lineLabel: widget.line.code),
    ));
  }

  /// Güzergâh çizgisi üzerine gidiş yönü okları.
  List<Marker> _directionArrows() {
    final pts = _drawRoute;
    if (pts.length < 2) return const [];
    final spacing = _arrowSpacing;
    if (_arrowsFor == spacing && _arrowsRouteLen == pts.length) return _arrows;
    const geo = Distance();
    final out = <Marker>[];
    var acc = 0.0;
    for (var i = 0; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      final len = geo.as(LengthUnit.Meter, a, b);
      if (len <= 0) continue;
      acc += len;
      if (acc < spacing) continue;
      acc = 0;
      final mid = LatLng(
          (a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2);
      final dLon =
          (b.longitude - a.longitude) * math.cos(a.latitude * math.pi / 180);
      final bearing = math.atan2(dLon, b.latitude - a.latitude);
      out.add(Marker(
        point: mid,
        width: 18,
        height: 18,
        child: IgnorePointer(
          child: Transform.rotate(
            angle: bearing,
            child: const Icon(Icons.navigation_rounded,
                size: 14, color: Colors.white),
          ),
        ),
      ));
    }
    _arrows = out;
    _arrowsFor = spacing;
    _arrowsRouteLen = pts.length;
    return out;
  }

  /// İşaretin yuvarlağı tam koordinata otursun diye hizalama (etiket kutuyu
  /// uzattığı için varsayılan hizalamada nokta yoldan aşağı kayıyor).
  static Alignment _dotAlignment(double dotBox, double totalHeight) =>
      Alignment(0, dotBox / totalHeight - 1);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final stops = _stops;
    final drawRoute = _drawRoute;
    final showLabels = _zoom >= _labelZoom;
    final color = lineColorOf(widget.line.color, widget.line.type);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: stops.isNotEmpty
                    ? LatLng(stops.first.lat, stops.first.lon)
                    : const LatLng(41.0082, 28.9784),
                initialZoom: _zoom,
                minZoom: 3,
                maxZoom: 18,
                backgroundColor: VigilantColors.surfaceContainerLowest,
                onMapReady: () {
                  _mapReady = true;
                  _fit();
                },
                onPositionChanged: (cam, _) {
                  final before = (_zoom >= _labelZoom, _arrowSpacing);
                  _zoom = cam.zoom;
                  if (mounted &&
                      before != (_zoom >= _labelZoom, _arrowSpacing)) {
                    setState(() {});
                  }
                },
                onTap: (_, __) {
                  if (_selected != null) setState(() => _selected = null);
                },
              ),
              children: [
                TileLayer(
                  keepBuffer: AppMapStyle.keepBuffer,
                  panBuffer: AppMapStyle.panBuffer,
                  urlTemplate: AppMapStyle.urlTemplate,
                  subdomains: AppMapStyle.subdomains,
                  userAgentPackageName: 'com.originstudios.stopalert',
                  retinaMode: AppMapStyle.supportsRetina &&
                      RetinaMode.isHighDensity(context),
                ),
                if (AppMapStyle.needsLabelOverlay)
                  TileLayer(
                    keepBuffer: AppMapStyle.keepBuffer,
                    panBuffer: AppMapStyle.panBuffer,
                    urlTemplate: AppMapStyle.labelOverlayUrl,
                    subdomains: AppMapStyle.labelSubdomains,
                    userAgentPackageName: 'com.originstudios.stopalert',
                  ),
                if (drawRoute.length >= 2)
                  PolylineLayer(polylines: [
                    Polyline(
                      points: drawRoute,
                      strokeWidth: 5,
                      color: color.withValues(alpha: 0.85),
                      borderStrokeWidth: 1,
                      borderColor: Colors.white.withValues(alpha: 0.25),
                    ),
                  ]),
                MarkerLayer(markers: _directionArrows()),
                // Ara duraklar
                MarkerLayer(markers: [
                  for (var i = 0; i < stops.length; i++)
                    if (i != 0 && i != stops.length - 1)
                      _stopMarker(stops[i], color, showLabels: showLabels),
                ]),
                // Başlangıç ve bitiş
                MarkerLayer(markers: [
                  if (stops.isNotEmpty)
                    _terminalMarker(stops.first, isStart: true),
                  if (stops.length > 1)
                    _terminalMarker(stops.last, isStart: false),
                ]),
              ],
            ),
          ),
          _topBar(context, text, color),
          if (_selected case final s?)
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: _StopCard(
                stop: s,
                index: stops.indexWhere((x) => x.id == s.id) + 1,
                total: stops.length,
                accent: color,
                onClose: () => setState(() => _selected = null),
                onSetAlarm: () => _setAlarm(s),
              ),
            )
          else
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: _HintCard(
                  stopCount: stops.length, lineName: widget.line.name),
            ),
        ],
      ),
    );
  }

  Marker _stopMarker(Stop s, Color color, {required bool showLabels}) {
    final selected = _selected?.id == s.id;
    const dotBox = 24.0;
    final height = showLabels ? 58.0 : dotBox;
    return Marker(
      point: LatLng(s.lat, s.lon),
      width: showLabels ? 132 : dotBox,
      height: height,
      alignment:
          showLabels ? _dotAlignment(dotBox, height) : Alignment.center,
      child: GestureDetector(
        onTap: () {
          Haptics.light();
          setState(() => _selected = selected ? null : s);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: dotBox,
              height: dotBox,
              child: Center(
                child: Container(
                  width: selected ? 18 : 12,
                  height: selected ? 18 : 12,
                  decoration: BoxDecoration(
                    color: selected ? color : VigilantColors.background,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: selected
                            ? Colors.white
                            : color.withValues(alpha: 0.85),
                        width: 2.5),
                  ),
                ),
              ),
            ),
            if (showLabels)
              Flexible(child: _MapLabel(text: s.name, highlight: selected)),
          ],
        ),
      ),
    );
  }

  Marker _terminalMarker(Stop s, {required bool isStart}) {
    final selected = _selected?.id == s.id;
    const dotBox = 30.0;
    const height = 66.0;
    return Marker(
      point: LatLng(s.lat, s.lon),
      width: 140,
      height: height,
      alignment: _dotAlignment(dotBox, height),
      child: GestureDetector(
        onTap: () {
          Haptics.light();
          setState(() => _selected = selected ? null : s);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: dotBox,
              height: dotBox,
              child: Center(
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: isStart
                        ? VigilantColors.secondary
                        : VigilantColors.primary,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2.5),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.45),
                          blurRadius: 6,
                          offset: const Offset(0, 2)),
                    ],
                  ),
                  child: Icon(
                      isStart ? Icons.trip_origin_rounded : Icons.flag_rounded,
                      size: 14,
                      color: Colors.white),
                ),
              ),
            ),
            Flexible(
              child:
                  _MapLabel(text: s.name, highlight: selected, strong: true),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context, TextTheme text, Color color) {
    return Positioned(
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
              Flexible(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: VigilantColors.surfaceContainer
                        .withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(lineTypeIcon(widget.line.type),
                          size: 16, color: color),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text('${widget.line.code} · güzergâh',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelLarge
                                ?.copyWith(fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              _RoundBtn(
                icon: Icons.center_focus_strong_rounded,
                onTap: () {
                  Haptics.light();
                  _fit();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Harita üzerindeki durak adı etiketi.
class _MapLabel extends StatelessWidget {
  const _MapLabel({
    required this.text,
    this.highlight = false,
    this.strong = false,
  });

  final String text;
  final bool highlight;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: highlight
            ? VigilantColors.primary
            : Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 2,
        textAlign: TextAlign.center,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: Colors.white,
          fontSize: strong ? 10.5 : 9.5,
          height: 1.15,
          fontWeight: strong ? FontWeight.w800 : FontWeight.w600,
        ),
      ),
    );
  }
}

/// Durak seçilmeden önceki ipucu kartı.
class _HintCard extends StatelessWidget {
  const _HintCard({required this.stopCount, required this.lineName});

  final int stopCount;
  final String lineName;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerLow.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: VigilantColors.surfaceVariant.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.touch_app_rounded,
              color: VigilantColors.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(lineName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        text.bodyMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text('$stopCount durak · alarm kurmak için bir durağa dokun',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Seçili durak kartı — doğrudan alarm kurma.
class _StopCard extends StatelessWidget {
  const _StopCard({
    required this.stop,
    required this.index,
    required this.total,
    required this.accent,
    required this.onClose,
    required this.onSetAlarm,
  });

  final Stop stop;
  final int index;
  final int total;
  final Color accent;
  final VoidCallback onClose;
  final VoidCallback onSetAlarm;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerLow.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 20),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('$index/$total',
                    style: text.labelSmall?.copyWith(
                        color: accent, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(stop.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style:
                        text.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
              ),
              GestureDetector(
                onTap: onClose,
                behavior: HitTestBehavior.opaque,
                child: const Icon(Icons.close_rounded,
                    size: 20, color: VigilantColors.onSurfaceVariant),
              ),
            ],
          ),
          if (stop.contextLabel.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(stop.contextLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.labelMedium
                    ?.copyWith(color: VigilantColors.onSurfaceVariant)),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onSetAlarm,
              icon: const Icon(Icons.alarm_add_rounded, size: 18),
              label: const Text('Bu durağa alarm kur'),
              style: FilledButton.styleFrom(
                backgroundColor: VigilantColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
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
      color: VigilantColors.surfaceContainer.withValues(alpha: 0.94),
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
