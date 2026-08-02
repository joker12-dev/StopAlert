import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../data/models.dart';
import '../engine/geo.dart' as geo;
import '../services/routing_service.dart';
import '../theme/app_theme.dart';
import '../util/map_style.dart';
import '../util/platform_check.dart';

/// Koyu temalı OpenStreetMap (CartoDB dark tiles — ücretsiz, anahtarsız).
///
/// Seçili hattın yolunu ışıltılı bir çizgiyle çizer; her durağı nokta,
/// biniş/iniş ve kullanıcı konumunu belirgin işaretlerle gösterir.
/// Fare tekerleği, çift dokunuş, pinch ve +/- butonlarıyla yakınlaştırılabilir.
class RouteMap extends StatefulWidget {
  const RouteMap({
    super.key,
    this.line,
    this.boardingStopId,
    this.targetStopId,
    this.currentLocation,
    this.interactive = true,
    this.initialZoom = 13,
    this.autoFit = true,
    this.followButton = false,
    this.initialFollow = false,
    this.showProgress = false,
  });

  final TransitLine? line;
  final String? boardingStopId;
  final String? targetStopId;
  final LatLng? currentLocation;

  /// true ise geçilen güzergâh kısmı soluk, kalan kısım parlak çizilir
  /// (canlı takipte "ne kadar yol kaldı" hissi).
  final bool showProgress;

  /// false ise dokunma/zoom kapalı ve zoom butonları gizli (kart içi mini harita).
  final bool interactive;
  final double initialZoom;

  /// false ise konum her değiştiğinde kamera yeniden sığdırılmaz (canlı takip:
  /// harita sürekli zıplamasın). Hat değişince yine sığdırır.
  final bool autoFit;

  /// true ise "konumuma ortala" butonu gösterilir: basınca kamera kullanıcı
  /// konumuna kilitlenir ve onu izler; kullanıcı haritayı ELLE oynattığı anda
  /// izleme kendiliğinden durur (buton tekrar basılana dek).
  final bool followButton;

  /// Takip kilidi ekran açılır açılmaz aktif başlasın mı (canlı takip: true).
  final bool initialFollow;

  @override
  State<RouteMap> createState() => _RouteMapState();
}

class _RouteMapState extends State<RouteMap> {
  final _controller = MapController();
  bool _ready = false;
  late bool _follow = widget.initialFollow;

  /// Hattı YOLLARA oturtan OSRM polyline'ı (boşsa düz çizgiye düşülür).
  List<LatLng> _road = const [];

  @override
  void initState() {
    super.initState();
    _loadRoad();
  }

  /// Hattın duraklarını KARAYOLUNA oturtan rotayı arka planda yükle.
  ///
  /// YALNIZCA lastikli taşıtlar için anlamlıdır: Marmaray/metro/tramvay kendi
  /// rayında, vapur denizde gider — onları karayolu rotasına oturtmak saçma
  /// bir güzergâh çiziyordu. Bu türlerde duraklar arası düz çizgi kullanılır.
  Future<void> _loadRoad() async {
    if (!isMobileDevice) return; // testler/masaüstü: ağ isteği yapma
    final type = widget.line?.type;
    if (type != LineType.bus) return;
    final pts = _linePoints;
    if (pts.length < 2) return;
    final road = await RoutingService.instance.route(pts);
    if (mounted && road.length >= 2) setState(() => _road = road);
  }

  /// Durak isim etiketleri yalnızca yeterince yakınlaşınca gösterilir
  /// (uzaktayken harita kalabalıklaşmasın).
  static const _labelZoomThreshold = 14.0;
  bool _showLabels = false;

  /// Anlık yakınlaşma — yön oklarının sıklığını belirler.
  double _currentZoom = 13;

  List<Stop> get _stops => widget.line?.stops ?? const <Stop>[];

  List<LatLng> get _linePoints => [
        for (final s in _stops)
          if (s.lat != 0 || s.lon != 0) LatLng(s.lat, s.lon),
      ];

  @override
  void didUpdateWidget(RouteMap old) {
    super.didUpdateWidget(old);
    final lineChanged = old.line?.id != widget.line?.id;
    final locChanged = old.currentLocation != widget.currentLocation;
    if (lineChanged) {
      _road = const [];
      _loadRoad();
    }
    if (lineChanged || (widget.autoFit && locChanged)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
      return;
    }
    // Takip kilidi: her konum güncellemesinde kamerayı kullanıcıya taşı
    // (zoom'a dokunmadan). Kullanıcı elle oynatınca _follow zaten kapanır.
    final loc = widget.currentLocation;
    if (_follow && locChanged && loc != null && _ready) {
      _controller.move(loc, _controller.camera.zoom);
    }
  }

  void _enableFollow() {
    setState(() => _follow = true);
    final loc = widget.currentLocation;
    if (loc != null && _ready) {
      final zoom = _controller.camera.zoom;
      _controller.move(loc, zoom < 15 ? 15 : zoom);
    }
  }

  void _fit() {
    final pts = [
      ..._linePoints,
      if (widget.currentLocation != null) widget.currentLocation!,
    ];
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _controller.move(pts.first, 15);
      return;
    }
    _controller.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(pts),
        padding: const EdgeInsets.all(56),
      ),
    );
  }

  void _zoom(double delta) {
    if (!_ready) return;
    final cam = _controller.camera;
    _controller.move(cam.center, (cam.zoom + delta).clamp(3.0, 18.0));
  }

  // Oklar çizgi/zoom değişmedikçe yeniden hesaplanmaz (OSRM çizgisi binlerce
  // noktadan oluşabiliyor).
  List<Marker> _arrows = const [];
  double? _arrowsFor;
  int _arrowsLen = -1;

  /// Ok sıklığı kademesi — yalnızca kademe değişince yeniden çizilir.
  int get _arrowSpacingBucket =>
      _currentZoom >= 15.5 ? 2 : (_currentZoom >= 14 ? 1 : 0);

  /// Güzergâh üzerine aralıklarla yerleştirilen yön okları.
  List<Marker> _directionArrows(List<LatLng> pts) {
    if (pts.length < 2) return const [];
    // Yakınlaştıkça sıklaşır; uzakta çizgiyi boğmasın.
    final spacing = _currentZoom >= 15.5
        ? 300.0
        : _currentZoom >= 14
            ? 600.0
            : 1200.0;
    if (_arrowsFor == spacing && _arrowsLen == pts.length) return _arrows;
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
      final dLon =
          (b.longitude - a.longitude) * math.cos(a.latitude * math.pi / 180);
      out.add(Marker(
        point: LatLng((a.latitude + b.latitude) / 2,
            (a.longitude + b.longitude) / 2),
        width: 18,
        height: 18,
        child: IgnorePointer(
          child: Transform.rotate(
            angle: math.atan2(dLon, b.latitude - a.latitude),
            child: const Icon(Icons.navigation_rounded,
                size: 13, color: Colors.white),
          ),
        ),
      ));
    }
    _arrows = out;
    _arrowsFor = spacing;
    _arrowsLen = pts.length;
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final linePts = _linePoints;
    // Yollara oturmuş rota varsa onu çiz; yoksa düz durak-arası çizgi.
    final drawPts = _road.length >= 2 ? _road : linePts;
    final center = widget.currentLocation ??
        (linePts.isNotEmpty ? linePts.first : const LatLng(41.0082, 28.9784));
    final lineColor = widget.line != null
        ? lineTypeColor(widget.line!.type)
        : VigilantColors.primary;

    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: center,
            initialZoom: widget.initialZoom,
            minZoom: 3,
            maxZoom: 18,
            backgroundColor: VigilantColors.surfaceContainerLowest,
            interactionOptions: InteractionOptions(
              flags: widget.interactive
                  ? InteractiveFlag.drag |
                      InteractiveFlag.pinchZoom |
                      InteractiveFlag.doubleTapZoom |
                      InteractiveFlag.scrollWheelZoom |
                      InteractiveFlag.flingAnimation
                  : InteractiveFlag.none,
            ),
            onMapReady: () {
              _ready = true;
              _fit();
            },
            onPositionChanged: (camera, hasGesture) {
              // Kullanıcı haritayı ELLE oynattıysa takip kilidini bırak.
              if (hasGesture && _follow) setState(() => _follow = false);
              final show = camera.zoom >= _labelZoomThreshold;
              // Ok sıklığı eşiği de zoom'a bağlı; ikisi birlikte tazelenir.
              final before = _arrowSpacingBucket;
              _currentZoom = camera.zoom;
              if (show != _showLabels || before != _arrowSpacingBucket) {
                setState(() => _showLabels = show);
              }
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
            // Uydu görünümünde yol/durak adları okunsun diye ince etiket katmanı.
            if (AppMapStyle.needsLabelOverlay)
              TileLayer(
                urlTemplate: AppMapStyle.labelOverlayUrl,
                subdomains: AppMapStyle.labelSubdomains,
                userAgentPackageName: 'com.originstudios.stopalert',
                retinaMode: AppMapStyle.supportsRetina &&
                    RetinaMode.isHighDensity(context),
              ),
            if (drawPts.length >= 2)
              if (_progressSplit(drawPts) case (final passed, final remaining))
                ...[
                  // Geçilen kısım: soluk, ışımasız.
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: passed,
                        strokeWidth: 5,
                        color: lineColor.withValues(alpha: 0.28),
                      ),
                    ],
                  ),
                  // Kalan kısım: ışıma + net çizgi.
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: remaining,
                        strokeWidth: 12,
                        color: lineColor.withValues(alpha: 0.25),
                      ),
                    ],
                  ),
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: remaining,
                        strokeWidth: 5,
                        color: lineColor,
                        borderStrokeWidth: 1.5,
                        borderColor: Colors.white.withValues(alpha: 0.35),
                      ),
                    ],
                  ),
                ]
              else ...[
                // Alt katman: geniş, yumuşak "ışıma".
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: drawPts,
                      strokeWidth: 12,
                      color: lineColor.withValues(alpha: 0.25),
                    ),
                  ],
                ),
                // Üst katman: net çizgi.
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: drawPts,
                      strokeWidth: 5,
                      color: lineColor,
                      borderStrokeWidth: 1.5,
                      borderColor: Colors.white.withValues(alpha: 0.35),
                    ),
                  ],
                ),
              ],
            // Gidiş yönü okları — çizgiye bakınca hangi uçtan hangi uca
            // gidildiği anlaşılmıyordu.
            if (widget.interactive) MarkerLayer(markers: _directionArrows(drawPts)),
            // Ara durak noktaları
            MarkerLayer(
              markers: [
                for (final s in _stops)
                  if ((s.lat != 0 || s.lon != 0) &&
                      s.id != widget.boardingStopId &&
                      s.id != widget.targetStopId)
                    Marker(
                      point: LatLng(s.lat, s.lon),
                      width: 14,
                      height: 14,
                      child: _StopDot(color: lineColor),
                    ),
              ],
            ),
            // Durak isim etiketleri (yakınlaşınca)
            if (_showLabels && widget.interactive)
              MarkerLayer(
                markers: [
                  for (final s in _stops)
                    if (s.lat != 0 || s.lon != 0)
                      Marker(
                        point: LatLng(s.lat, s.lon),
                        width: 130,
                        height: 46,
                        alignment: Alignment.topCenter,
                        child: _StopLabel(name: s.name),
                      ),
                ],
              ),
            // Ana işaretler: biniş, iniş, konum
            MarkerLayer(
              markers: [
                if (_stopLatLng(widget.boardingStopId) case final p?)
                  Marker(
                    point: p,
                    width: 34,
                    height: 34,
                    child: const _PinMarker(
                      color: VigilantColors.secondary,
                      icon: Icons.trip_origin,
                    ),
                  ),
                if (_stopLatLng(widget.targetStopId) case final p?)
                  Marker(
                    point: p,
                    width: 44,
                    height: 44,
                    alignment: Alignment.topCenter,
                    child: const _TargetMarker(),
                  ),
                if (widget.currentLocation != null)
                  Marker(
                    point: widget.currentLocation!,
                    width: 30,
                    height: 30,
                    child: const _LocationDot(),
                  ),
              ],
            ),
          ],
        ),
        // Küçük, göze batmayan atıf (ücretsiz döşeme sağlayıcının şartı).
        Positioned(
          left: 8,
          bottom: 6,
          child: IgnorePointer(
            child: Text(
              AppMapStyle.attribution,
              style: TextStyle(
                fontSize: 9,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ),
          ),
        ),
        // Zoom butonları — sağ ortada, panelin altında kalmaz.
        if (widget.interactive)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.followButton) ...[
                    _ZoomButton(
                      icon: Icons.my_location,
                      iconColor: _follow ? VigilantColors.accentBlue : null,
                      onTap: _enableFollow,
                    ),
                    const SizedBox(height: 8),
                  ],
                  _ZoomButton(icon: Icons.add, onTap: () => _zoom(1)),
                  const SizedBox(height: 8),
                  _ZoomButton(icon: Icons.remove, onTap: () => _zoom(-1)),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Konumu güzergâh çizgisine oturtup "geçilen" ve "kalan" iki parçaya böler.
  /// [showProgress] kapalıysa ya da konum yoksa null döner (tek parça çizilir).
  (List<LatLng>, List<LatLng>)? _progressSplit(List<LatLng> pts) {
    final loc = widget.currentLocation;
    if (!widget.showProgress || loc == null || pts.length < 2) return null;
    final geoPts = [for (final p in pts) geo.LatLng(p.latitude, p.longitude)];
    final proj = geo.projectOntoLine(
      geo.LatLng(loc.latitude, loc.longitude),
      geoPts,
    );
    final seg = proj.segmentIndex.clamp(0, pts.length - 2);
    final snap = LatLng(proj.snapped.lat, proj.snapped.lon);
    final passed = <LatLng>[
      for (var i = 0; i <= seg; i++) pts[i],
      snap,
    ];
    final remaining = <LatLng>[
      snap,
      for (var i = seg + 1; i < pts.length; i++) pts[i],
    ];
    return (passed, remaining);
  }

  LatLng? _stopLatLng(String? id) {
    final line = widget.line;
    if (line == null || id == null) return null;
    final i = line.indexOfStop(id);
    if (i == -1) return null;
    final s = line.stops[i];
    if (s.lat == 0 && s.lon == 0) return null;
    return LatLng(s.lat, s.lon);
  }
}

class _StopLabel extends StatelessWidget {
  const _StopLabel({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    // Etiket, durak noktasının hemen üstünde durur.
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: VigilantColors.background.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: VigilantColors.onSurface,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

class _StopDot extends StatelessWidget {
  const _StopDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.background,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 2.5),
      ),
    );
  }
}

class _PinMarker extends StatelessWidget {
  const _PinMarker({required this.color, required this.icon});

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.background,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 3),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 10),
        ],
      ),
      child: Icon(icon, color: color, size: 16),
    );
  }
}

class _TargetMarker extends StatelessWidget {
  const _TargetMarker();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VigilantColors.tertiaryContainer,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: VigilantColors.tertiaryContainer.withValues(alpha: 0.6),
            blurRadius: 14,
          ),
        ],
      ),
      child: const Icon(Icons.flag, color: Colors.white, size: 22),
    );
  }
}

class _LocationDot extends StatefulWidget {
  const _LocationDot();

  @override
  State<_LocationDot> createState() => _LocationDotState();
}

class _LocationDotState extends State<_LocationDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, child) {
        final t = _c.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            // Dışa doğru genişleyip solan nabız halkası
            Container(
              width: 12 + t * 18,
              height: 12 + t * 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color:
                    VigilantColors.accentBlue.withValues(alpha: (1 - t) * 0.4),
              ),
            ),
            child!,
          ],
        );
      },
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: VigilantColors.accentBlue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: VigilantColors.accentBlue.withValues(alpha: 0.7),
              blurRadius: 12,
            ),
          ],
        ),
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({required this.icon, required this.onTap, this.iconColor});

  final IconData icon;
  final VoidCallback onTap;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: VigilantColors.surfaceContainerHigh.withValues(alpha: 0.92),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 4,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon,
              color: iconColor ?? VigilantColors.onSurface, size: 22),
        ),
      ),
    );
  }
}
