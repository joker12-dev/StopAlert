import 'package:flutter_test/flutter_test.dart';
import 'package:stopalert/src/data/timetable.dart';
import 'package:stopalert/src/services/timetable_service.dart';

/// Sefer saati ayrıştırma — gerçek İETT yanıtından alınmış satırlarla.
///
/// Alan adları ve gün tipi harfleri servisin kendi sözleşmesi; burada
/// sabitlenmezse bir alan adı değiştiğinde saatler sessizce boşalır.
void main() {
  // api.ibb.gov.tr/iett/UlasimAnaVeri/PlanlananSeferSaati.asmx yanıtından.
  List<Map<String, dynamic>> rows() => [
        {
          'SHATKODU': '147',
          'SGUZERAH': '147_D_D0',
          'SYON': 'D',
          'SGUNTIPI': 'I',
          'SSERVISTIPI': 'Normal',
          'DT': '06:05',
        },
        {
          'SHATKODU': '147',
          'SGUZERAH': '147_G_D0',
          'SYON': 'G',
          'SGUNTIPI': 'I',
          'SSERVISTIPI': 'Gareli',
          'DT': '05:35',
        },
        {
          'SHATKODU': '147',
          'SGUZERAH': '147_G_D0',
          'SYON': 'G',
          'SGUNTIPI': 'C',
          'SSERVISTIPI': 'Normal',
          'DT': '07:10',
        },
        {
          'SHATKODU': '147',
          'SGUZERAH': '147_G_D0',
          'SYON': 'G',
          'SGUNTIPI': 'P',
          'SSERVISTIPI': 'Normal',
          'DT': '08:00',
        },
      ];

  group('Gün tipi', () {
    test('İETT harfleri doğru takvime eşlenir', () {
      expect(DayType.fromCode('I'), DayType.weekday);
      expect(DayType.fromCode('C'), DayType.saturday);
      expect(DayType.fromCode('P'), DayType.sunday);
      expect(DayType.fromCode('X'), isNull);
      expect(DayType.fromCode(null), isNull);
    });

    test('takvim tarihe göre seçilir', () {
      // 2026-08-08 cumartesi, 2026-08-09 pazar, 2026-08-10 pazartesi.
      expect(DayType.forDate(DateTime(2026, 8, 8)), DayType.saturday);
      expect(DayType.forDate(DateTime(2026, 8, 9)), DayType.sunday);
      expect(DayType.forDate(DateTime(2026, 8, 10)), DayType.weekday);
    });
  });

  group('Ayrıştırma', () {
    test('yön, gün tipi ve servis notu okunur', () {
      final list = TimetableService.parseRows(rows());
      expect(list.length, 4);

      final gareli = list.firstWhere((d) => d.time == '05:35');
      expect(gareli.outbound, isTrue, reason: 'SYON=G gidiş demek');
      expect(gareli.dayType, DayType.weekday);
      // "Normal" bilgi taşımaz, elenmeli; istisna korunmalı.
      expect(gareli.serviceNote, 'Gareli');
      expect(list.firstWhere((d) => d.time == '06:05').serviceNote, isEmpty);
      expect(list.firstWhere((d) => d.time == '06:05').outbound, isFalse);
    });

    test('bilinmeyen gün tipi ve bozuk saat ATILIR', () {
      // Hangi takvime ait olduğu belli olmayan saati göstermek, kullanıcıyı
      // olmayan bir sefere yollamak olurdu.
      final list = TimetableService.parseRows([
        {'SGUNTIPI': 'Z', 'SYON': 'G', 'DT': '09:00'},
        {'SGUNTIPI': 'I', 'SYON': 'G', 'DT': ''},
        {'SGUNTIPI': 'I', 'SYON': 'G', 'DT': 'sabah'},
        {'SGUNTIPI': 'I', 'SYON': 'G', 'DT': '09:15'},
      ]);
      expect(list.length, 1);
      expect(list.single.time, '09:15');
    });
  });

  group('Takvim sorguları', () {
    test('gün + yön süzgeci ve saat sıralaması', () {
      final t = Timetable(
        lineCode: '147',
        departures: TimetableService.parseRows(rows()),
      );
      expect(t.forDay(DayType.weekday, outbound: true).map((d) => d.time),
          ['05:35']);
      expect(t.forDay(DayType.weekday, outbound: false).map((d) => d.time),
          ['06:05']);
      expect(t.forDay(DayType.sunday, outbound: true).map((d) => d.time),
          ['08:00']);
      expect(t.hasDay(DayType.saturday), isTrue);
    });

    test('sıradaki kalkış şu andan SONRAKİ ilk saat', () {
      final t = Timetable(
        lineCode: 'T',
        departures: TimetableService.parseRows([
          {'SGUNTIPI': 'I', 'SYON': 'G', 'DT': '07:00'},
          {'SGUNTIPI': 'I', 'SYON': 'G', 'DT': '08:30'},
          {'SGUNTIPI': 'I', 'SYON': 'G', 'DT': '09:45'},
        ]),
      );
      final day = t.forDay(DayType.weekday, outbound: true);

      expect(t.next(day, DateTime(2026, 8, 10, 7, 30))?.time, '08:30');
      // Tam kalkış dakikasında o sefer HÂLÂ sıradakidir.
      expect(t.next(day, DateTime(2026, 8, 10, 8, 30))?.time, '08:30');
      // Gün bittiyse yarını uydurmaz.
      expect(t.next(day, DateTime(2026, 8, 10, 22, 0)), isNull);
    });
  });
}
