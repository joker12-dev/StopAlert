import 'package:flutter/material.dart';

import '../services/permission_service.dart';
import '../theme/app_theme.dart';
import '../util/haptics.dart';

/// Alarm kurulamıyor: eksik izinleri anlatan ve tek dokunuşla isteten sayfa.
///
/// NEDEN VAR: izin kapısı yalnızca ilk açılışta çıkıyor. Kullanıcı orada
/// "sonra" derse ya da izni sonradan sistem ayarlarından kaparsa alarm sessizce
/// çalışmıyordu — telefon cebinde, uygulama açık, alarm hiç çalmıyor. Bunu
/// kullanıcının durağı kaçırdığında öğrenmesi kabul edilemez.
///
/// SESSİZ BAŞARISIZLIK YERİNE AÇIK RET: eksik izinle alarm kurulmasına izin
/// vermiyoruz, sebebini söylüyoruz ve düzeltmenin yolunu veriyoruz.
class PermissionRequiredSheet extends StatefulWidget {
  const PermissionRequiredSheet({super.key, required this.report});

  final PermissionStatusReport report;

  /// Eksik izin varsa sayfayı gösterir ve kullanıcı düzelttiyse `true` döner.
  ///
  /// Hiç eksik yoksa sayfa hiç açılmaz ve `true` döner — çağıran koşulsuz
  /// çağırabilsin.
  static Future<bool> ensure(BuildContext context) async {
    final report = await PermissionService().check();
    if (report.criticalGranted) return true;
    if (!context.mounted) return false;
    final fixed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PermissionRequiredSheet(report: report),
    );
    return fixed ?? false;
  }

  @override
  State<PermissionRequiredSheet> createState() =>
      _PermissionRequiredSheetState();
}

class _PermissionRequiredSheetState extends State<PermissionRequiredSheet> {
  late PermissionStatusReport _report = widget.report;
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    Haptics.light();
    await action();
    final fresh = await PermissionService().check();
    if (!mounted) return;
    setState(() {
      _report = fresh;
      _busy = false;
    });
    // Hepsi tamamlandıysa sayfayı kapat: kullanıcıyı bekletmenin anlamı yok.
    if (fresh.criticalGranted && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final service = PermissionService();
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        decoration: BoxDecoration(
          color: VigilantColors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
              color: VigilantColors.surfaceVariant.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: VigilantColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Center(
              child: Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: VigilantColors.primary.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.notifications_active_outlined,
                    size: 30, color: VigilantColors.primary),
              ),
            ),
            const SizedBox(height: 14),
            Text('Alarm çalamaz',
                textAlign: TextAlign.center,
                style: text.headlineSmall?.copyWith(fontSize: 21)),
            const SizedBox(height: 6),
            Text(
              'Bu izinler olmadan durağa yaklaştığında seni uyandıramayız. '
              'Alarmın gerçekten çalması için tamamla.',
              textAlign: TextAlign.center,
              style: text.bodySmall
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            if (!_report.locationWhenInUse)
              _PermRow(
                icon: Icons.my_location_rounded,
                title: 'Konum izni',
                detail: 'Durağa ne kadar kaldığını konumundan hesaplıyoruz.',
                busy: _busy,
                onFix: () => _run(service.requestWhenInUse),
              ),
            if (_report.locationWhenInUse && !_report.locationAlways)
              _PermRow(
                icon: Icons.location_on_outlined,
                title: 'Her zaman konum',
                detail: 'Telefon cebindeyken ve ekran kapalıyken de takip '
                    'edebilmek için gerekli.',
                busy: _busy,
                onFix: () => _run(service.requestAlways),
              ),
            if (!_report.notifications)
              _PermRow(
                icon: Icons.notifications_outlined,
                title: 'Bildirim izni',
                detail: 'Alarm bir bildirim olarak çalıyor.',
                busy: _busy,
                onFix: () => _run(service.requestNotifications),
              ),
            if (!_report.fullScreenIntent)
              _PermRow(
                icon: Icons.fullscreen_rounded,
                title: 'Tam ekran alarm',
                detail: 'Ekran kilitliyken alarmın çalar saat gibi açılması '
                    'için.',
                busy: _busy,
                onFix: () => _run(service.requestFullScreenIntent),
              ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Şimdi değil',
                  style: TextStyle(color: VigilantColors.onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tek bir eksik izin satırı — açıklama + "İzin ver" düğmesi.
class _PermRow extends StatelessWidget {
  const _PermRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.busy,
    required this.onFix,
  });

  final IconData icon;
  final String title;
  final String detail;
  final bool busy;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: VigilantColors.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: VigilantColors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: text.labelLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(detail,
                    style: text.labelSmall?.copyWith(
                        color: VigilantColors.onSurfaceVariant, height: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: busy ? null : onFix,
            style: FilledButton.styleFrom(
              backgroundColor: VigilantColors.primary,
              foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('İzin ver'),
          ),
        ],
      ),
    );
  }
}
