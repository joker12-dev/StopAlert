import 'package:flutter/material.dart';

import '../services/bus_data_service.dart';
import '../theme/app_theme.dart';
import '../widgets/mascot.dart';

/// İlk açılış VERİ PAKETLERİ ekranı. Otomatik geçmez — kullanıcı ne indirdiğini
/// görür ve "Devam Et" ile ilerler. İstanbul otobüs paketi indirilir; ray/vapur
/// zaten gömülü; Kocaeli/Sakarya gibi bölgeler "yakında" (ileride manuel indirme).
class DataBootstrapScreen extends StatefulWidget {
  const DataBootstrapScreen({super.key, required this.onCompleted});

  final VoidCallback onCompleted;

  @override
  State<DataBootstrapScreen> createState() => _DataBootstrapScreenState();
}

class _DataBootstrapScreenState extends State<DataBootstrapScreen> {
  BusDataPhase _phase = BusDataPhase.checking;
  double _frac = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    await BusDataService.instance.ensureReady(
      onProgress: (phase, frac) {
        if (!mounted) return;
        setState(() {
          _phase = phase;
          _frac = frac;
        });
      },
    );
  }

  bool get _busDone =>
      _phase == BusDataPhase.ready ||
      _phase == BusDataPhase.offline ||
      _phase == BusDataPhase.skipped;

  String get _busStatus {
    switch (_phase) {
      case BusDataPhase.checking:
        return 'Sürüm kontrol ediliyor…';
      case BusDataPhase.downloading:
        return 'İniyor · %${(_frac * 100).clamp(0, 100).toStringAsFixed(0)}';
      case BusDataPhase.verifying:
        return 'Doğrulanıyor…';
      case BusDataPhase.ready:
      case BusDataPhase.skipped:
        return 'Hazır · çevrimdışı kullanılabilir';
      case BusDataPhase.offline:
        return 'Çevrimdışı — sonra tekrar denenecek';
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                children: [
                  const Center(
                    child: AnimatedMascot(MascotAssets.poseTelefon, height: 130),
                  ),
                  const SizedBox(height: 20),
                  Text('Veri Paketleri',
                      textAlign: TextAlign.center, style: text.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    'Durak ve hat verileri cihazına inince yeraltında bile '
                    'çalışır. İndir, çevrimdışı kullan.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 28),
                  _PackageCard(
                    icon: Icons.directions_transit_rounded,
                    title: 'İstanbul · Ray & Vapur',
                    subtitle: 'Marmaray, metro, tramvay, vapur',
                    status: _PkgStatus.ready,
                    statusText: 'Gömülü · Hazır',
                  ),
                  const SizedBox(height: 12),
                  _PackageCard(
                    icon: Icons.directions_bus_filled_rounded,
                    title: 'İstanbul · Otobüs (İETT)',
                    subtitle: '785 hat · ~13.000 durak · resmi veri',
                    status: _busDone
                        ? (_phase == BusDataPhase.offline
                            ? _PkgStatus.offline
                            : _PkgStatus.ready)
                        : _PkgStatus.downloading,
                    statusText: _busStatus,
                    progress:
                        _phase == BusDataPhase.downloading ? _frac : null,
                  ),
                  const SizedBox(height: 12),
                  const _PackageCard(
                    icon: Icons.directions_bus_outlined,
                    title: 'Kocaeli · Otobüs',
                    subtitle: 'Yakında — manuel indirme',
                    status: _PkgStatus.soon,
                    statusText: 'Yakında',
                  ),
                  const SizedBox(height: 12),
                  const _PackageCard(
                    icon: Icons.directions_bus_outlined,
                    title: 'Sakarya · Otobüs',
                    subtitle: 'Yakında — manuel indirme',
                    status: _PkgStatus.soon,
                    statusText: 'Yakında',
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Icon(Icons.map_rounded,
                          size: 16, color: VigilantColors.onSurfaceVariant),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Harita internetle canlı yüklenir (paket gerekmez).',
                          style: text.labelMedium?.copyWith(
                              color: VigilantColors.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Lisans şartı: kaynak atfı (İBB Açık Veri / CC BY 4.0).
                  Text(
                    'Otobüs ve durak verileri İETT · İBB Açık Veri Portalı’ndan '
                    'alınmıştır. Harita © OpenStreetMap katkıcıları.',
                    textAlign: TextAlign.center,
                    style: text.labelSmall
                        ?.copyWith(color: VigilantColors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            // Otomatik GEÇMEZ — kullanıcı görür ve buradan ilerler.
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: SizedBox(
                height: 54,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: VigilantColors.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _busDone ? widget.onCompleted : null,
                  child: Text(
                    _busDone ? 'Devam Et' : 'İndiriliyor…',
                    style: text.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700, color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _PkgStatus { ready, downloading, offline, soon }

class _PackageCard extends StatelessWidget {
  const _PackageCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.status,
    required this.statusText,
    this.progress,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final _PkgStatus status;
  final String statusText;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final soon = status == _PkgStatus.soon;
    final Color accent = switch (status) {
      _PkgStatus.ready => VigilantColors.secondary,
      _PkgStatus.downloading => VigilantColors.primary,
      _PkgStatus.offline => VigilantColors.tertiaryContainer,
      _PkgStatus.soon => VigilantColors.onSurfaceVariant,
    };
    return Opacity(
      opacity: soon ? 0.55 : 1,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: VigilantColors.surfaceContainer,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: VigilantColors.surfaceVariant.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: 0.15),
                  ),
                  child: Icon(icon, size: 22, color: accent),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.labelMedium?.copyWith(
                              color: VigilantColors.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      Text(statusText,
                          style: text.labelMedium?.copyWith(
                              color: accent, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _trailing(accent),
              ],
            ),
            if (progress != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress!.clamp(0.0, 1.0),
                  minHeight: 5,
                  backgroundColor: VigilantColors.surfaceContainerHigh,
                  valueColor:
                      const AlwaysStoppedAnimation(VigilantColors.primary),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _trailing(Color accent) {
    switch (status) {
      case _PkgStatus.ready:
        return Icon(Icons.check_circle_rounded, color: accent, size: 24);
      case _PkgStatus.downloading:
        return const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
              strokeWidth: 2.4, color: VigilantColors.primary),
        );
      case _PkgStatus.offline:
        return Icon(Icons.wifi_off_rounded, color: accent, size: 22);
      case _PkgStatus.soon:
        return Icon(Icons.lock_clock_rounded, color: accent, size: 20);
    }
  }
}
