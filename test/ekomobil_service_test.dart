import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:stopalert/src/services/ekomobil_service.dart';

void main() {
  group('EkomobilService', () {
    test('security token is md5(timestamp + secret)', () {
      expect(
        EkomobilService.tokenForTimestamp('1755450000000'),
        '6e1a86052be38410729aaba59025662b',
      );
    });

    test('parses live vehicle text response', () {
      final vehicles = EkomobilService.parseVehicles(
        '40.889038+29.237083+41 AUJ 804+0\n'
        '40.808594+29.371752+41 AIG 611+1\n',
        routeCode: '200',
        direction: 0,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(1755450000000),
      );

      expect(vehicles, hasLength(2));
      expect(vehicles.first.lat, 40.889038);
      expect(vehicles.first.lon, 29.237083);
      expect(vehicles.first.plate, '41 AUJ 804');
      expect(vehicles.first.routeCode, '200_G_STOPALERT');
      expect(vehicles.first.isGidis, isTrue);
      expect(vehicles.first.nearestStopCode, isEmpty);
    });

    test('parses html input response from live endpoint', () {
      final vehicles = EkomobilService.parseVehicles(
        '<li><input value="40.906754+29.208094+41 AIG 604+1"></input></li>'
        '<li><input value="40.90685+29.20851+41 AUJ 805+0"></input></li>'
        '<li id="busOnStopData" style="display:none">'
        '<input value="1,0,0,0,1,0,0"></li>',
        routeCode: '200',
        direction: 0,
      );

      expect(vehicles, hasLength(2));
      expect(vehicles.first.plate, '41 AIG 604');
      expect(vehicles.last.routeCode, '200_G_STOPALERT');
    });

    test('adds fresh token headers to vehicle request', () async {
      final now = DateTime.fromMillisecondsSinceEpoch(1755450000000);
      late Uri requestedUri;
      late Map<String, String> requestedHeaders;
      final service = EkomobilService(
        now: () => now,
        client: MockClient((request) async {
          requestedUri = request.url;
          requestedHeaders = request.headers;
          return http.Response('40.1+29.1+41 ABC 123+0', 200);
        }),
      );

      final vehicles = await service.vehiclePositions('200', direction: 1);

      expect(vehicles, hasLength(1));
      expect(requestedUri.queryParameters['cmd'], 'searchBusesontheRoute');
      expect(requestedUri.queryParameters['route_code'], '200');
      expect(requestedUri.queryParameters['direction'], '1');
      expect(requestedHeaders['X-Security-Timestamp'], '1755450000000');
      expect(
        requestedHeaders['X-Security-Token'],
        '6e1a86052be38410729aaba59025662b',
      );
      expect(vehicles.first.routeCode, '200_D_STOPALERT');
    });
  });
}
