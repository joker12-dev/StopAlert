import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'iett_service.dart';

/// e-Komobil passenger information endpoints used by Kocaeli's web client.
class EkomobilService {
  EkomobilService({
    http.Client? client,
    DateTime Function()? now,
  })  : _client = client ?? http.Client(),
        _now = now ?? DateTime.now;

  static final EkomobilService instance = EkomobilService();

  static const _baseUrl =
      'https://e-komobil.com/yolcu_bilgilendirme_operations.php';
  static const _secretKey = 'ekomobil_web_2024_secure_key';

  final http.Client _client;
  final DateTime Function() _now;

  static String tokenForTimestamp(String timestamp) =>
      md5.convert(utf8.encode('$timestamp$_secretKey')).toString();

  static Map<String, String> securityHeaders(DateTime at) {
    final timestamp = at.millisecondsSinceEpoch.toString();
    return {
      'X-Security-Timestamp': timestamp,
      'X-Security-Token': tokenForTimestamp(timestamp),
    };
  }

  /// Live vehicles on a route direction. Direction follows the web endpoint:
  /// 0 = first/outbound table, 1 = second/inbound table.
  Future<List<BusVehicle>> vehiclePositions(
    String routeCode, {
    required int direction,
  }) async {
    final code = routeCode.trim();
    if (code.isEmpty || (direction != 0 && direction != 1)) {
      return const [];
    }

    final at = _now();
    final uri = Uri.parse(_baseUrl).replace(queryParameters: {
      'cmd': 'searchBusesontheRoute',
      'route_code': code,
      'direction': '$direction',
    });

    try {
      final res = await _client.get(uri, headers: {
        'Accept': 'text/plain, */*',
        ...securityHeaders(at),
      }).timeout(const Duration(seconds: 12));
      if (res.statusCode != 200) return const [];
      return parseVehicles(
        utf8.decode(res.bodyBytes),
        routeCode: code,
        direction: direction,
        fetchedAt: at,
      );
    } catch (_) {
      return const [];
    }
  }

  static List<BusVehicle> parseVehicles(
    String body, {
    required String routeCode,
    required int direction,
    DateTime? fetchedAt,
  }) {
    final normalized = body.replaceAll(
      RegExp(r'<br\s*/?>', caseSensitive: false),
      '\n',
    );
    final records = _vehicleRecords(normalized);
    final out = <BusVehicle>[];
    final dirCode = direction == 1 ? 'D' : 'G';
    final lastSeen = fetchedAt?.toIso8601String() ?? '';

    for (final rawLine in records) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final parts = line.split('+');
      if (parts.length < 3) continue;

      final lat = double.tryParse(parts[0].trim().replaceAll(',', '.'));
      final lon = double.tryParse(parts[1].trim().replaceAll(',', '.'));
      if (lat == null || lon == null) continue;

      final plate = parts[2].trim();
      out.add(BusVehicle(
        plate: plate,
        lat: lat,
        lon: lon,
        headingTo: direction == 1 ? 'D\u00f6n\u00fc\u015f' : 'Gidi\u015f',
        routeCode: '${routeCode}_${dirCode}_STOPALERT',
        lastSeen: lastSeen,
        nearestStopCode: '',
      ));
    }
    return out;
  }

  static List<String> _vehicleRecords(String body) {
    final values = RegExp(
      r'value\s*=\s*"([^"]*)"',
      caseSensitive: false,
    ).allMatches(body).map((m) => m.group(1) ?? '').toList();
    if (values.isNotEmpty) return values;
    return body.split(RegExp(r'[\r\n]+'));
  }
}
