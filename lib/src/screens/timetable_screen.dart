import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart' show TemplateType;

import '../data/models.dart';
import '../data/timetable.dart';
import '../data/transit_city.dart';
import '../services/timetable_service.dart';
import '../theme/app_theme.dart';
import '../widgets/native_ad_slot.dart';
import '../util/haptics.dart';
import '../util/insets.dart';

/// Bir hattın SEFER SAATLERİ — hafta içi / cumartesi / pazar ayrı sekmelerde.
///
/// Üç takvim gerçekten farklı (hafta içi sık, hafta sonu seyrek); tek listede
/// birleştirmek yanıltıcı olurdu. Açılışta BUGÜNÜN sekmesi ve şu andan sonraki
/// ilk kalkış seçili gelir — kullanıcının sorusu neredeyse her zaman "bir
/// sonraki otobüs ne zaman".
class TimetableScreen extends StatefulWidget {
  const TimetableScreen({
    super.key,
    required this.lineCode,
    required this.lineName,
    this.city,
    this.type,
    this.outboundLabel = 'Gidiş',
    this.inboundLabel = 'Dönüş',
  });

  final String lineCode;
  final String lineName;

  /// Hattın şehri — saatlerin nereden okunacağını belirler (İETT servisi mi,
  /// indirilen paket mi).
  final TransitCity? city;

  /// Hattın TÜRÜ — kaynağı belirler: otobüs saatleri İETT servisinden,
  /// metro/Marmaray/tramvay/vapur saatleri indirilen paketten gelir.
  final LineType? type;
  final String outboundLabel;
  final String inboundLabel;

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  Timetable? _table;
  bool _loading = true;
  late DayType _day = DayType.forDate(DateTime.now());
  bool _outbound = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await TimetableService.instance
        .forLine(widget.lineCode, city: widget.city, type: widget.type);
    if (!mounted) return;
    setState(() {
      _table = t;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final table = _table;
    final rows = table?.forDay(_day, outbound: _outbound) ?? const <Departure>[];
    final now = DateTime.now();
    final isToday = _day == DayType.forDate(now);
    final next = isToday ? table?.next(rows, now) : null;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Sefer Saatleri'),
            Text(
              '${widget.lineCode} · ${widget.lineName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelSmall
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Gün tipi seçimi
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                for (final d in DayType.values) ...[
                  Expanded(
                    child: _Chip(
                      label: d.label,
                      selected: _day == d,
                      onTap: () {
                        Haptics.selection();
                        setState(() => _day = d);
                      },
                    ),
                  ),
                  if (d != DayType.values.last) const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          // Yön seçimi
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Row(
              children: [
                Expanded(
                  child: _Chip(
                    label: widget.outboundLabel,
                    selected: _outbound,
                    onTap: () {
                      Haptics.selection();
                      setState(() => _outbound = true);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _Chip(
                    label: widget.inboundLabel,
                    selected: !_outbound,
                    onTap: () {
                      Haptics.selection();
                      setState(() => _outbound = false);
                    },
                  ),
                ),
              ],
            ),
          ),
          if (next != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: VigilantColors.secondary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                      color: VigilantColors.secondary.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.schedule,
                        size: 16, color: VigilantColors.secondary),
                    const SizedBox(width: 10),
                    Text(
                      'Sıradaki kalkış ${next.time}',
                      style: text.labelLarge
                          ?.copyWith(color: VigilantColors.secondary),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          // Gün/yön seçicinin altında, saat listesinin üstünde yerel reklam.
          const NativeAdSlot(
            key: ValueKey('timetable-native-ad'),
            margin: EdgeInsets.fromLTRB(16, 0, 16, 8),
            template: TemplateType.small,
          ),
          Expanded(child: _body(rows, next)),
        ],
      ),
    );
  }

  /// Gece yarısını aşan seferlerin başlığı.
  ///
  /// Bunlar bugünün gecesine ait: cuma gecesi 01:28'de kalkan tren cuma
  /// sayfasında durur, cumartesi sayfasının ilk treni DEĞİLDİR.
  Widget _nextDayHeader(TextTheme text) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 6, 0, 12),
        child: Row(
          children: [
            const Expanded(child: Divider(color: VigilantColors.surfaceVariant)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.bedtime_outlined,
                      size: 14, color: VigilantColors.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Text(
                    _day == DayType.weekday
                        // Cuma ayrı bir gün tipi değil; uzatma yalnızca cuma
                        // gecesi işliyor ve bunu söylemek zorundayız.
                        ? 'GECE SEFERLERİ · ERTESİ GÜN (cuma geceleri)'
                        : 'GECE SEFERLERİ · ERTESİ GÜN',
                    style: text.labelSmall?.copyWith(
                        color: VigilantColors.onSurfaceVariant,
                        letterSpacing: 0.8),
                  ),
                ],
              ),
            ),
            const Expanded(child: Divider(color: VigilantColors.surfaceVariant)),
          ],
        ),
      );

  Widget _body(List<Departure> rows, Departure? next) {
    final text = Theme.of(context).textTheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rows.isEmpty) {
      final hasAny = !(_table?.isEmpty ?? true);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.event_busy_outlined,
                  size: 40, color: VigilantColors.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                hasAny
                    // Veri geldi ama bu gün/yön boş: hat o gün çalışmıyor.
                    ? 'Bu yönde ${_day.label.toLowerCase()} seferi yok.'
                    // Hiç veri gelmedi: ağ yok ya da servis bu hattı vermiyor.
                    // Ray hatlarının saatleri PAKETTE; ağ değil, eski paket
                    // sorunu olabiliyor ve kullanıcı bağlantısını boş yere
                    // kurcalıyordu.
                    : widget.type != null &&
                            widget.type != LineType.bus &&
                            widget.type != LineType.metrobus
                        ? 'Bu hattın sefer saatleri veri paketinde yok. '
                            'Ayarlar → Veri Paketleri’nden paketi güncelle.'
                        : 'Sefer saati alınamadı. İnternet bağlantını kontrol '
                            'edip tekrar dene.',
                textAlign: TextAlign.center,
                style: text.bodyMedium
                    ?.copyWith(color: VigilantColors.onSurfaceVariant),
              ),
              if (!hasAny) ...[
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: () {
                    setState(() => _loading = true);
                    _load();
                  },
                  icon: const Icon(Icons.refresh),
                  label: const Text('Tekrar dene'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // Saatler saat başına gruplanır: 60+ kalkışlık düz bir liste okunmuyor.
    //
    // GECE YARISINI AŞAN seferler ayrı bir kümede toplanır ve listenin SONUNA
    // konur: cuma gecesi 01:28'de kalkan tren cumaya aittir, cumartesinin ilk
    // treni değildir. Saat başı anahtarı 24+ değerini koruduğu için sıralama
    // kendiliğinden doğru çıkıyor ("24", "25" > "23").
    final byHour = <String, List<Departure>>{};
    for (final d in rows) {
      final h = (d.minuteOfDay ~/ 60).toString().padLeft(2, '0');
      byHour.putIfAbsent(h, () => []).add(d);
    }
    final hours = byHour.keys.toList()..sort();
    final nextDayCount = rows.where((d) => d.isNextDay).length;

    return ListView.builder(
      padding: EdgeInsets.fromLTRB(16, 0, 16, AppInsets.listBottom(context)),
      // +1 satır: gece bloğunun başlığı (varsa).
      itemCount: hours.length + (nextDayCount > 0 ? 1 : 0),
      itemBuilder: (context, i) {
        // GECE BLOĞU AYRACI: ilk 24+ saatinden hemen önce.
        if (nextDayCount > 0) {
          final firstLate = hours.indexWhere((h) => (int.tryParse(h) ?? 0) >= 24);
          if (firstLate != -1) {
            if (i == firstLate) return _nextDayHeader(text);
            if (i > firstLate) i -= 1;
          }
        }
        final hour = hours[i];
        final items = byHour[hour]!;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 44,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    // 24+ saat başlığı normal saate çevrilir ("24" → "00").
                    ((int.tryParse(hour) ?? 0) % 24).toString().padLeft(2, '0'),
                    style: text.titleMedium?.copyWith(
                      color: VigilantColors.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final d in items)
                      _TimePill(departure: d, highlight: identical(d, next)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TimePill extends StatelessWidget {
  const _TimePill({required this.departure, required this.highlight});

  final Departure departure;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final note = departure.serviceNote;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: highlight
            ? VigilantColors.secondary.withValues(alpha: 0.18)
            : VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: highlight
            ? Border.all(color: VigilantColors.secondary.withValues(alpha: 0.6))
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // 24+ biçimi kullanıcıya normal saat olarak yazılır.
            departure.displayTime,
            style: text.titleSmall?.copyWith(
              color: highlight ? VigilantColors.secondary : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (note.isNotEmpty)
            Text(
              note,
              style: text.labelSmall
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Material(
      color: selected
          ? VigilantColors.primary.withValues(alpha: 0.16)
          : VigilantColors.surfaceContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: selected
                ? Border.all(
                    color: VigilantColors.primary.withValues(alpha: 0.5))
                : null,
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.labelLarge?.copyWith(
              color: selected
                  ? VigilantColors.primary
                  : VigilantColors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
