import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/journey_record.dart';
import '../data/journey_stats.dart';
import '../state/journey_provider.dart';
import '../state/settings_provider.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';
import '../widgets/banner_ad_slot.dart';
import 'history_screen.dart';
import 'settings_screen.dart';

/// Profil — gerçek Firestore yolculuk geçmişinden istatistikler, paylaşılabilir
/// özet kartı ve son aktivite (tam geçmiş için Geçmiş ekranı).
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final journeys = ref.watch(journeysStreamProvider).valueOrNull ?? const [];
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    final stats = JourneyStats.from(journeys);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
          children: [
            // Başlık
            Row(
              children: [
                const Icon(Icons.account_circle_outlined,
                    color: VigilantColors.primary, size: 26),
                const SizedBox(width: 8),
                Expanded(child: Text('Profil', style: text.headlineSmall)),
                IconButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                  icon: const Icon(Icons.settings_outlined,
                      color: VigilantColors.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // Kimlik
            Center(
              child: Column(
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: VigilantColors.surfaceContainer,
                      border: Border.all(
                          color: VigilantColors.primaryContainer, width: 2),
                    ),
                    child: const CircleAvatar(
                      backgroundColor: VigilantColors.surfaceContainerHigh,
                      child: Icon(Icons.person_outline,
                          size: 44, color: VigilantColors.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(settings.nickname, style: text.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    'StopAlert Yolcusu',
                    style: text.labelLarge
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Paylaşılabilir istatistik özet kartı
            _StatSummaryCard(stats: stats, nickname: settings.nickname),
            const SizedBox(height: 16),
            // İkincil istatistikler
            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    label: 'Kaç kez uyandın',
                    icon: Icons.notifications_active_outlined,
                    iconColor: VigilantColors.primary,
                    value: '${stats.completedJourneys}',
                    unit: 'kez',
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _StatTile(
                    label: 'En çok hat',
                    icon: Icons.star_outline,
                    iconColor: VigilantColors.tertiaryContainer,
                    value: stats.mostUsedLineCode ?? '—',
                    unit: stats.mostUsedLineCode == null
                        ? ''
                        : '×${stats.mostUsedCount}',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // Son aktiviteler + tümünü gör
            Container(
              decoration: BoxDecoration(
                color: VigilantColors.surfaceContainer,
                borderRadius: BorderRadius.circular(24),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child:
                              Text('Son Yolculuklar', style: text.labelLarge),
                        ),
                        if (journeys.isNotEmpty)
                          TextButton(
                            onPressed: () {
                              Haptics.light();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const HistoryScreen()),
                              );
                            },
                            child: Text('Tümünü Gör',
                                style: text.labelLarge
                                    ?.copyWith(color: VigilantColors.primary)),
                          ),
                      ],
                    ),
                  ),
                  Divider(
                      height: 1, color: Colors.white.withValues(alpha: 0.05)),
                  if (journeys.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        children: [
                          const Icon(Icons.history,
                              size: 36, color: VigilantColors.outline),
                          const SizedBox(height: 10),
                          Text(
                            'Henüz yolculuk yok.\nBir alarm kurup tamamladığında '
                            'burada görünecek.',
                            textAlign: TextAlign.center,
                            style: text.bodyMedium?.copyWith(
                                color: VigilantColors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    )
                  else
                    for (var i = 0; i < journeys.length && i < 6; i++)
                      _ActivityRow(
                        record: journeys[i],
                        isLast: i == journeys.length - 1 || i == 5,
                      ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const BannerAdSlot(),
          ],
        ),
      ),
    );
  }
}

/// Paylaşılabilir istatistik özet kartı (hat çizgisi + rakamlar; emojisiz).
class _StatSummaryCard extends StatelessWidget {
  const _StatSummaryCard({required this.stats, required this.nickname});

  final JourneyStats stats;
  final String nickname;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF6E120C), Color(0xFF2A1512)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.insights, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'StopAlert karnem',
                  style: text.labelLarge?.copyWith(
                    color: Colors.white.withValues(alpha: 0.8),
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () {
                  Haptics.light();
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(
                      content:
                          Text('Kart paylaşımı yakında (görsel kart hazır).'),
                    ));
                },
                icon: const Icon(Icons.ios_share, size: 16),
                label: const Text('Paylaş'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _BigStat(value: '${stats.totalJourneys}', label: 'yolculuk'),
              const SizedBox(width: 24),
              _BigStat(value: stats.totalDurationText, label: 'yolda'),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                const Icon(Icons.notifications_active,
                    size: 16, color: Colors.white),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    stats.isEmpty
                        ? 'İlk yolculuğunu kur, karnen dolmaya başlasın.'
                        : '${stats.completedJourneys} kez tam zamanında '
                            'uyandırıldın'
                            '${stats.mostUsedLineCode != null ? ' · en çok ${stats.mostUsedLineCode}' : ''}.',
                    style: text.labelMedium
                        ?.copyWith(color: Colors.white.withValues(alpha: 0.9)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BigStat extends StatelessWidget {
  const _BigStat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: text.headlineLarge?.copyWith(color: Colors.white, fontSize: 30),
        ),
        Text(
          label,
          style: text.labelMedium
              ?.copyWith(color: Colors.white.withValues(alpha: 0.7)),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.unit,
  });

  final String label;
  final IconData icon;
  final Color iconColor;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelLarge
                      ?.copyWith(color: VigilantColors.onSurfaceVariant),
                ),
              ),
              Icon(icon, size: 20, color: iconColor),
            ],
          ),
          const SizedBox(height: 12),
          RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              text: value,
              style: text.headlineMedium,
              children: [
                if (unit.isNotEmpty)
                  TextSpan(
                    text: ' $unit',
                    style: text.bodyMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.record, this.isLast = false});

  final JourneyRecord record;
  final bool isLast;

  String _relativeTime(DateTime? t) {
    if (t == null) return 'şimdi';
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'şimdi';
    if (diff.inMinutes < 60) return '${diff.inMinutes} dk önce';
    if (diff.inHours < 24) return '${diff.inHours} sa önce';
    if (diff.inDays == 1) return 'Dün';
    if (diff.inDays < 7) return '${diff.inDays} gün önce';
    return '${t.day}.${t.month}.${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final mins = record.durationSeconds ~/ 60;
    return Container(
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
              ),
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: VigilantColors.surfaceContainerHigh,
            ),
            child: Icon(lineTypeIcon(record.lineType),
                size: 20, color: lineTypeColor(record.lineType)),
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
                  style: text.bodyMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  '${record.lineCode} • ${mins < 1 ? '<1' : mins} dk',
                  style: text.labelMedium
                      ?.copyWith(color: VigilantColors.onSurfaceVariant),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _relativeTime(record.createdAt),
            style: text.labelMedium
                ?.copyWith(color: VigilantColors.outlineVariant),
          ),
        ],
      ),
    );
  }
}
