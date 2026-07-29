import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/journey_record.dart';
import '../data/models.dart';
import '../state/journey_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/skeleton.dart';

/// Geçmiş Yolculuklar — tarih/hat/güzergâh/süre + hat türü ve durum filtresi,
/// güne göre gruplanmış tam liste (Firestore geçmişi).
class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  LineType? _typeFilter; // null = tüm türler
  String _statusFilter = 'all'; // all | completed | cancelled

  static const _months = [
    'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
    'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık',
  ];

  String _dayLabel(DateTime? t) {
    if (t == null) return 'Tarihsiz';
    final now = DateTime.now();
    final d = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(d).inDays;
    if (diff == 0) return 'Bugün';
    if (diff == 1) return 'Dün';
    if (diff > 1 && diff < 7) return '$diff gün önce';
    return '${t.day} ${_months[t.month - 1]} ${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final async = ref.watch(journeysStreamProvider);
    final journeys = async.valueOrNull ?? const <JourneyRecord>[];

    // Filtreleme.
    final filtered = journeys.where((j) {
      if (_typeFilter != null && j.lineType != _typeFilter) return false;
      if (_statusFilter == 'completed' && j.status != 'completed') return false;
      if (_statusFilter == 'cancelled' && j.status != 'cancelled') return false;
      return true;
    }).toList();

    // Veride var olan hat türleri (filtre çipleri için).
    final presentTypes = <LineType>{for (final j in journeys) j.lineType}.toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('Geçmiş'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Durum filtresi (segmentli)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
            child: _StatusSegments(
              value: _statusFilter,
              onChanged: (v) => setState(() => _statusFilter = v),
            ),
          ),
          // Hat türü çipleri
          if (presentTypes.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  _FilterChip(
                    label: 'Tümü',
                    selected: _typeFilter == null,
                    onTap: () => setState(() => _typeFilter = null),
                  ),
                  for (final t in presentTypes)
                    _FilterChip(
                      label: t.label,
                      selected: _typeFilter == t,
                      color: lineTypeColor(t),
                      onTap: () => setState(() => _typeFilter = t),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: _buildBody(context, text, async.isLoading, filtered),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    TextTheme text,
    bool loading,
    List<JourneyRecord> filtered,
  ) {
    if (loading && filtered.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: const [
          SkeletonTile(),
          SizedBox(height: 12),
          SkeletonTile(),
          SizedBox(height: 12),
          SkeletonTile(),
        ],
      );
    }
    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.filter_alt_off_outlined,
                  size: 40, color: VigilantColors.outline),
              const SizedBox(height: 12),
              Text(
                'Bu filtreyle yolculuk yok.',
                style: text.bodyMedium
                    ?.copyWith(color: VigilantColors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    // Güne göre gruplama (liste zaten en yeni önce sıralı).
    final items = <Widget>[];
    String? currentDay;
    for (final j in filtered) {
      final label = _dayLabel(j.createdAt);
      if (label != currentDay) {
        currentDay = label;
        items.add(Padding(
          padding: EdgeInsets.only(top: items.isEmpty ? 4 : 20, bottom: 8),
          child: Text(
            label,
            style: text.labelLarge?.copyWith(
              color: VigilantColors.onSurfaceVariant,
              letterSpacing: 0.5,
            ),
          ),
        ));
      }
      items.add(Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _HistoryRow(record: j),
      ));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: items,
    );
  }
}

class _StatusSegments extends StatelessWidget {
  const _StatusSegments({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  static const _options = [
    ('all', 'Tümü'),
    ('completed', 'Tamamlanan'),
    ('cancelled', 'İptal'),
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (final (key, label) in _options)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(key),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: key == value
                        ? VigilantColors.primary
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    label,
                    style: text.labelLarge?.copyWith(
                      color: key == value
                          ? VigilantColors.onPrimary
                          : VigilantColors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.color,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final accent = color ?? VigilantColors.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: selected
                ? accent.withValues(alpha: 0.18)
                : VigilantColors.surfaceContainer,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.5)
                  : Colors.white.withValues(alpha: 0.06),
            ),
          ),
          child: Text(
            label,
            style: text.labelMedium?.copyWith(
              color: selected ? accent : VigilantColors.onSurfaceVariant,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.record});

  final JourneyRecord record;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final color = lineTypeColor(record.lineType);
    final mins = record.durationSeconds ~/ 60;
    final cancelled = record.status == 'cancelled';
    final time = record.createdAt;
    final hhmm = time == null
        ? ''
        : '${time.hour.toString().padLeft(2, '0')}:'
            '${time.minute.toString().padLeft(2, '0')}';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.15),
            ),
            child: Icon(lineTypeIcon(record.lineType), size: 20, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${record.boardingStopName} → ${record.targetStopName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      '${record.lineCode} • ${mins < 1 ? '<1' : mins} dk'
                      '${hhmm.isNotEmpty ? ' • $hhmm' : ''}',
                      style: text.labelMedium
                          ?.copyWith(color: VigilantColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (cancelled)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: VigilantColors.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('İptal',
                  style: text.labelSmall
                      ?.copyWith(color: VigilantColors.error)),
            )
          else
            const Icon(Icons.check_circle,
                size: 18, color: VigilantColors.secondary),
        ],
      ),
    );
  }
}
