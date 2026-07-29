/// StopAlert çekirdek veri modelleri.
///
/// Veri kaynağı: İBB GTFS'inden üretilen gömülü assets/data/lines.json
/// (bkz. tool/gtfs_to_assets.dart). Otobüs/minibüs katmanı Faz 2'de
/// SQLite ile eklenecek.
library;

enum LineType {
  marmaray('Marmaray'),
  metro('Metro'),
  tram('Tramvay'),
  funicular('Füniküler'),
  cableCar('Teleferik'),
  ferry('Vapur'),
  bus('Otobüs');

  const LineType(this.label);

  final String label;

  static LineType fromName(String name) => LineType.values.firstWhere(
        (t) => t.name == name,
        orElse: () => LineType.bus,
      );
}

class Stop {
  const Stop({
    required this.id,
    required this.name,
    this.lat = 0,
    this.lon = 0,
    this.underground = false,
    this.direction = '',
  });

  factory Stop.fromJson(Map<String, dynamic> json) => Stop(
        id: json['id'] as String,
        name: json['name'] as String,
        lat: (json['lat'] as num?)?.toDouble() ?? 0,
        lon: (json['lon'] as num?)?.toDouble() ?? 0,
        underground: json['underground'] as bool? ?? false,
        direction: json['direction'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': lat,
        'lon': lon,
        'underground': underground,
        if (direction.isNotEmpty) 'direction': direction,
      };

  final String id;
  final String name;
  final double lat;
  final double lon;

  /// GPS'in çalışmadığı (tünel/denizaltı) istasyon.
  final bool underground;

  /// Aynı adlı durakları ayırmak için yön/peron bilgisi (İETT stop_desc);
  /// ray/vapur için boş.
  final String direction;
}

class TransitLine {
  const TransitLine({
    required this.id,
    required this.code,
    required this.name,
    required this.type,
    required this.stops,
    this.segmentSeconds,
    this.defaultSegmentSeconds = 120,
  });

  factory TransitLine.fromJson(Map<String, dynamic> json) => TransitLine(
        id: json['id'] as String,
        code: json['code'] as String,
        name: json['name'] as String,
        type: LineType.fromName(json['type'] as String),
        stops: [
          for (final s in json['stops'] as List)
            Stop.fromJson(s as Map<String, dynamic>),
        ],
        segmentSeconds: (json['segmentSeconds'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'name': name,
        'type': type.name,
        'stops': [for (final s in stops) s.toJson()],
        'segmentSeconds': segmentSeconds,
      };

  final String id;

  /// Hattın kısa kodu: "M2", "T1", "Marmaray".
  final String code;
  final String name;
  final LineType type;

  /// Duraklar hat yönünde sıralıdır; ters yön listeyi tersine çevirerek elde edilir.
  final List<Stop> stops;

  /// GTFS'ten gelen gerçek durak arası süreler (saniye);
  /// i. eleman stops[i] -> stops[i+1] arasıdır.
  final List<int>? segmentSeconds;

  /// Segment verisi yoksa kullanılan varsayılan durak arası süre.
  final int defaultSegmentSeconds;

  int indexOfStop(String stopId) => stops.indexWhere((s) => s.id == stopId);

  /// [from] -> [to] arası durak sayısı; yön fark etmez.
  int stopsBetween(String from, String to) =>
      (indexOfStop(to) - indexOfStop(from)).abs();

  /// [from] -> [to] arası tahmini süre (GTFS segment süreleri varsa onlarla).
  Duration estimatedTravelTime(String from, String to) {
    final a = indexOfStop(from);
    final b = indexOfStop(to);
    if (a == -1 || b == -1) return Duration.zero;
    final lo = a < b ? a : b;
    final hi = a < b ? b : a;
    final segs = segmentSeconds;
    if (segs != null && segs.length >= stops.length - 1) {
      var total = 0;
      for (var i = lo; i < hi; i++) {
        total += segs[i];
      }
      return Duration(seconds: total);
    }
    return Duration(seconds: (hi - lo) * defaultSegmentSeconds);
  }
}

/// Kullanıcının kurmakta olduğu yolculuk taslağı.
class JourneyDraft {
  const JourneyDraft({this.line, this.boardingStopId, this.targetStopId});

  final TransitLine? line;
  final String? boardingStopId;
  final String? targetStopId;

  bool get isComplete =>
      line != null && boardingStopId != null && targetStopId != null;

  Stop? get boardingStop => _stopById(boardingStopId);
  Stop? get targetStop => _stopById(targetStopId);

  Stop? _stopById(String? id) {
    if (line == null || id == null) return null;
    final i = line!.indexOfStop(id);
    return i == -1 ? null : line!.stops[i];
  }

  JourneyDraft copyWith({
    TransitLine? line,
    String? boardingStopId,
    String? targetStopId,
  }) {
    // Hat değişirse durak seçimleri geçersizdir.
    if (line != null && line.id != this.line?.id) {
      return JourneyDraft(line: line);
    }
    return JourneyDraft(
      line: line ?? this.line,
      boardingStopId: boardingStopId ?? this.boardingStopId,
      targetStopId: targetStopId ?? this.targetStopId,
    );
  }
}
