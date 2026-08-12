import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/account_service.dart';
import '../services/auth_service.dart';
import '../services/prediction_log.dart';
import '../services/segment_learning_store.dart';
import '../state/journey_provider.dart';
import '../state/settings_provider.dart';
import '../theme/app_theme.dart';
import '../util/insets.dart';
import '../data/alarm_sound.dart';
import '../services/alarm_sound_preview.dart';
import '../services/journey_reminder.dart';
import '../util/haptics.dart';
import '../util/platform_check.dart';
import 'data_packages_screen.dart';
import 'help_screen.dart';
import 'privacy_screen.dart';

/// Ayarlar — gerçek, kalıcı tercihler (bkz. [settingsProvider]).
///
/// Titreşim, alarm sesi ve erteleme süresi cihazda saklanır ve alarm akışını
/// besler. Henüz hazır olmayan bölümler bilgilendirici bir bildirim gösterir
/// (ölü dokunuş bırakılmaz).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _editNickname(
      BuildContext context, WidgetRef ref, String current) async {
    final controller = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VigilantColors.surfaceContainerHigh,
        title: const Text('Takma Ad'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Örn. Yolcu'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) {
      Haptics.selection();
      await ref.read(settingsProvider.notifier).setNickname(name);
    }
  }

  Future<void> _link(
    BuildContext context,
    WidgetRef ref,
    Future<AuthLinkResult> Function() action,
  ) async {
    Haptics.light();
    final messenger = ScaffoldMessenger.of(context);
    final result = await action();
    if (result.cancelled) return;

    // BAŞKA BİR KAYDA BAĞLI hesap: bağlamak mümkün değil ama GİRİŞ mümkün.
    // İkinci cihazda olan tam olarak budur — kullanıcı hesabına dönmek
    // istiyor, yeni bir bağ kurmak değil. Eskiden yalnızca "bu hesap zaten
    // kullanılıyor" deyip bırakıyorduk ve kullanıcının hesabına dönmesinin
    // hiçbir yolu yoktu.
    if (result.alreadyLinkedElsewhere && context.mounted) {
      final cred = result.credential!;
      final ok = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) => const _SignInSheet(),
      );
      if (ok ?? false) {
        final signed =
            await ref.read(authServiceProvider).signInWithCredential(cred);
        // GİRİŞ BAŞARILIYSA PROFİLİ GERİ YÜKLE: kullanıcı ikinci telefonunda
        // hesabına döndüğünde adı, alarm ayarları ve son aramaları da gelsin.
        final restored = signed.ok ? await _restoreProfile(ref) : false;
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Text(signed.ok
                ? (restored
                    ? 'Hesabına giriş yapıldı — ayarların ve aramaların geldi.'
                    : 'Hesabına giriş yapıldı.')
                : (signed.error ?? 'Giriş başarısız.')),
          ));
      }
      return;
    }

    // BAĞLAMA BAŞARILIYSA AYARLARI HEMEN BULUTA YAZ. Yalnızca "değişiklikte
    // yaz" kuralına bırakılırsa, bağladıktan sonra hiçbir ayarı
    // değiştirmeyen kullanıcının bulutta profili hiç oluşmuyor ve ikinci
    // cihazda geri gelecek bir şey bulunmuyordu.
    if (result.ok) {
      final current = ref.read(settingsProvider).valueOrNull;
      if (current != null) {
        await ref
            .read(profileRepositoryProvider)
            .saveSettings(current.toMap());
      }
      final recents = ref.read(recentSearchesProvider).valueOrNull;
      if (recents != null && recents.isNotEmpty) {
        await ref
            .read(profileRepositoryProvider)
            .saveRecents([for (final e in recents) e.toMap()]);
      }
    }

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(result.ok
            ? 'Hesap bağlandı — verilerin artık kalıcı.'
            : (result.error ?? 'Bağlama başarısız.')),
      ));
  }

  /// Buluttaki profili cihaza uygula. Kayıt yoksa `false` döner.
  ///
  /// Favoriler ve yolculuk geçmişi zaten canlı akışla geliyor (Firestore
  /// koleksiyonları); burada eksik olan ikisi taşınır: AYARLAR ve SON ARAMALAR.
  Future<bool> _restoreProfile(WidgetRef ref) async {
    final profile = await ref.read(profileRepositoryProvider).load();
    if (profile == null || profile.isEmpty) return false;
    final settings = profile.settings;
    if (settings != null) {
      await ref.read(settingsProvider.notifier).applyFromCloud(settings);
    }
    final recents = profile.recents;
    if (recents != null && recents.isNotEmpty) {
      await ref.read(recentSearchesProvider.notifier).mergeFromCloud(recents);
    }
    final stopRecents = profile.stopRecents;
    if (stopRecents != null && stopRecents.isNotEmpty) {
      await ref
          .read(stopRecentSearchesProvider.notifier)
          .mergeFromCloud(stopRecents);
    }
    return true;
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    Haptics.light();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VigilantColors.surfaceContainerHigh,
        title: const Text('Çıkış Yap'),
        content: const Text(
          'Bu cihazda anonim oturuma dönülecek; verilerine erişmek için '
          'tekrar aynı hesapla bağlanman gerekir.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Çıkış Yap'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(authServiceProvider).signOutToAnonymous();
  }

  Future<void> _deleteData(BuildContext context, WidgetRef ref) async {
    Haptics.light();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: VigilantColors.surfaceContainerHigh,
        title: const Text('Verilerimi Sil'),
        content: const Text(
          'Buluttaki yolculuk ve favori kayıtların ile cihazdaki ayar ve '
          'öğrenme verilerin kalıcı olarak silinecek. Bu işlem geri alınamaz.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: VigilantColors.error,
              foregroundColor: VigilantColors.onPrimary,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(accountServiceProvider).deleteAllData();
      // Etkilenen sağlayıcıları tazele.
      ref
        ..invalidate(settingsProvider)
        ..invalidate(recentSearchesProvider)
        ..invalidate(learnedSegmentCountProvider);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Verilerin silindi.')));
    } catch (_) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('Silme sırasında hata oldu, tekrar dene.'),
        ));
    }
  }

  Future<void> _pickAlarmSound(
      BuildContext context, WidgetRef ref, AppSettings s) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: VigilantColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => _AlarmSoundSheet(current: s.alarmSound),
    );
    if (choice != null) {
      Haptics.selection();
      await ref.read(settingsProvider.notifier).setAlarmSound(choice);
    }
    // Sayfa kapanınca önizleme sürmesin.
    await AlarmSoundPreview.stop();
  }

  Future<void> _pickDefaultTrigger(
      BuildContext context, WidgetRef ref, AppSettings s) async {
    final result =
        await showModalBottomSheet<({int mode, int distanceIndex, int stopsIndex})>(
      context: context,
      backgroundColor: VigilantColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => _DefaultTriggerSheet(
        mode: s.defaultTriggerMode,
        distanceIndex: s.defaultDistanceIndex,
        stopsIndex: s.defaultStopsIndex,
      ),
    );
    if (result != null) {
      Haptics.selection();
      await ref.read(settingsProvider.notifier).setDefaultTrigger(
            mode: result.mode,
            distanceIndex: result.distanceIndex,
            stopsIndex: result.stopsIndex,
          );
    }
  }

  Future<void> _pickMapStyle(
      BuildContext context, WidgetRef ref, AppSettings s) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: VigilantColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => _OptionSheet<String>(
        title: 'Harita Stili',
        current: s.mapTileStyle.name,
        options: const {
          'canli': 'Canlı (renkli, detaylı)',
          'gece': 'Gece (koyu)',
          'uydu': 'Uydu görüntüsü',
          'sade': 'Sade (açık)',
        },
      ),
    );
    if (choice != null) {
      Haptics.selection();
      await ref.read(settingsProvider.notifier).setMapStyle(choice);
    }
  }

  Future<void> _pickSnooze(
      BuildContext context, WidgetRef ref, AppSettings s) async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: VigilantColors.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => _OptionSheet<int>(
        title: 'Erteleme Süresi',
        current: s.snoozeMinutes,
        options: {for (final o in AppSettings.snoozeOptions) o: '$o dakika'},
      ),
    );
    if (choice != null) {
      Haptics.selection();
      await ref.read(settingsProvider.notifier).setSnoozeMinutes(choice);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    // Auth değişimlerini izle (bağla/çöz sonrası UI tazelensin).
    ref.watch(userChangesProvider);
    final auth = ref.read(authServiceProvider);
    final isLinked = auth.isLinked;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        title: const Text('Ayarlar'),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 8, 20, AppInsets.pageBottom(context) + 16),
        children: [
          // Profil özeti
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: VigilantColors.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: VigilantColors.primary.withValues(alpha: 0.2),
                  ),
                  child: const Icon(Icons.account_circle,
                      size: 40, color: VigilantColors.primary),
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(settings.nickname,
                        style: text.headlineSmall?.copyWith(fontSize: 20)),
                    Text(
                      isLinked
                          ? (auth.accountLabel ?? 'Bağlı hesap')
                          : 'Anonim (cihaz) hesap',
                      style: text.bodyMedium
                          ?.copyWith(color: VigilantColors.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _Section(
            title: 'HESAP',
            children: [
              _SettingsTile(
                icon: Icons.badge_outlined,
                title: 'Takma Ad',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(settings.nickname,
                        style: text.labelMedium
                            ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                    const Icon(Icons.chevron_right,
                        color: VigilantColors.onSurfaceVariant),
                  ],
                ),
                onTap: () => _editNickname(context, ref, settings.nickname),
              ),
              if (isLinked)
                _SettingsTile(
                  icon: Icons.verified_user_outlined,
                  title: 'Hesap',
                  subtitle: auth.accountLabel,
                  trailing: Text('Bağlı',
                      style: text.labelMedium
                          ?.copyWith(color: VigilantColors.secondary)),
                )
              else ...[
                _SettingsTile(
                  icon: Icons.g_mobiledata,
                  title: 'Google ile bağla',
                  subtitle: 'Verilerini kalıcılaştır (cihaz değişince kaybolmaz)',
                  trailing: const Icon(Icons.chevron_right,
                      color: VigilantColors.onSurfaceVariant),
                  onTap: () => _link(context, ref, auth.linkGoogle),
                ),
                // APPLE yalnızca iOS'ta: Android'de "Apple ile giriş"
                // akışı zaten çalışmıyor, düğme ölü dokunuş oluyordu.
                if (isIosDevice)
                  _SettingsTile(
                    icon: Icons.apple,
                    title: 'Apple ile bağla',
                    trailing: const Icon(Icons.chevron_right,
                        color: VigilantColors.onSurfaceVariant),
                    onTap: () => _link(context, ref, auth.linkApple),
                  ),
              ],
            ],
          ),
          _Section(
            title: 'BİLDİRİMLER',
            children: [
              _SettingsTile(
                icon: Icons.tune,
                title: 'Varsayılan Alarm',
                subtitle: 'Yeni alarmlar bu eşikle açılır',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(settings.defaultTriggerLabel,
                        style: text.labelMedium
                            ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                    const Icon(Icons.chevron_right,
                        color: VigilantColors.onSurfaceVariant),
                  ],
                ),
                onTap: () => _pickDefaultTrigger(context, ref, settings),
              ),
              _SettingsTile(
                icon: Icons.notifications_active_outlined,
                title: 'Alarm Sesi',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(settings.alarmSound,
                        style: text.labelMedium
                            ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                    const Icon(Icons.chevron_right,
                        color: VigilantColors.onSurfaceVariant),
                  ],
                ),
                onTap: () => _pickAlarmSound(context, ref, settings),
              ),
              _SettingsTile(
                icon: Icons.snooze,
                title: 'Erteleme Süresi',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${settings.snoozeMinutes} dk',
                        style: text.labelMedium
                            ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                    const Icon(Icons.chevron_right,
                        color: VigilantColors.onSurfaceVariant),
                  ],
                ),
                onTap: () => _pickSnooze(context, ref, settings),
              ),
              _SettingsTile(
                icon: Icons.vibration,
                title: 'Titreşim',
                trailing: Switch(
                  value: settings.vibration,
                  onChanged: (v) {
                    Haptics.selection();
                    ref.read(settingsProvider.notifier).setVibration(v);
                  },
                ),
              ),
              // ALIŞKANLIK HATIRLATMASI — alarmın kendisi değil, "yarın da
              // kuracak mısın?" hatırlatması.
              const _ReminderTile(),
            ],
          ),
          // ÖĞRENME: uygulama yolculuklardan segment sürelerini öğrenir;
          // yeraltı tahmini böylece kişisel olarak iyileşir.
          _LearningSection(),
          _Section(
            title: 'GÖRÜNÜM',
            children: [
              _SettingsTile(
                icon: Icons.dark_mode_outlined,
                title: 'Koyu Tema',
                subtitle: 'StopAlert koyu tema için tasarlandı',
                trailing: const Opacity(
                  opacity: 0.5,
                  child: Switch(value: true, onChanged: null),
                ),
              ),
              _SettingsTile(
                icon: Icons.map_outlined,
                title: 'Harita Stili',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(settings.mapStyleLabel,
                        style: text.labelMedium
                            ?.copyWith(color: VigilantColors.onSurfaceVariant)),
                    const Icon(Icons.chevron_right,
                        color: VigilantColors.onSurfaceVariant),
                  ],
                ),
                onTap: () => _pickMapStyle(context, ref, settings),
              ),
            ],
          ),
          _Section(
            title: 'VERİ',
            children: [
              // ŞEHİR SEÇİMİ YOK.
              //
              // Kullanıcı bir ilde yaşayıp öbürüne gidiyor; hangi ilde
              // olduğunu uygulamaya söylemek zorunda kalması gereksiz bir
              // ödevdi ve unutulduğunda arama yanlış ilde çalışıyordu. İndirilen
              // bütün paketler her yerde geçerli; hangi ile bakıldığı sonuçların
              // yanındaki rozette yazıyor.
              _SettingsTile(
                icon: Icons.sim_card_download_outlined,
                title: 'Veri Paketleri',
                subtitle: 'Şehir verilerini indir, güncelle veya sil',
                trailing: const Icon(Icons.chevron_right,
                    color: VigilantColors.onSurfaceVariant),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const DataPackagesScreen()),
                ),
              ),
            ],
          ),
          _Section(
            title: 'GİZLİLİK & KVKK',
            children: [
              _SettingsTile(
                icon: Icons.privacy_tip_outlined,
                title: 'Gizlilik & KVKK',
                trailing: const Icon(Icons.chevron_right,
                    color: VigilantColors.onSurfaceVariant),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PrivacyScreen()),
                ),
              ),
              _SettingsTile(
                icon: Icons.delete_forever_outlined,
                title: 'Verilerimi Sil',
                trailing: const Icon(Icons.chevron_right,
                    color: VigilantColors.error),
                onTap: () => _deleteData(context, ref),
              ),
            ],
          ),
          _Section(
            title: 'HAKKINDA',
            children: [
              _SettingsTile(
                icon: Icons.help_outline,
                title: 'Yardım Merkezi',
                trailing: const Icon(Icons.chevron_right,
                    color: VigilantColors.onSurfaceVariant),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const HelpScreen()),
                ),
              ),
              _SettingsTile(
                icon: Icons.description_outlined,
                title: 'Kullanım Koşulları',
                trailing: const Icon(Icons.chevron_right,
                    color: VigilantColors.onSurfaceVariant),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PrivacyScreen()),
                ),
              ),
              const _SettingsTile(
                icon: Icons.info_outline,
                title: 'Sürüm',
                trailing: Text('0.1.0',
                    style: TextStyle(color: VigilantColors.onSurfaceVariant)),
              ),
            ],
          ),
          // Çıkış — yalnızca hesap bağlıysa anlamlı (anonim oturuma döner).
          if (isLinked) ...[
            const SizedBox(height: 16),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: VigilantColors.error,
                side: const BorderSide(color: VigilantColors.error),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                textStyle: text.labelLarge,
              ),
              onPressed: () => _signOut(context, ref),
              icon: const Icon(Icons.logout),
              label: const Text('Çıkış Yap'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Seçenek listesi gösteren alt sayfa (alarm sesi / erteleme süresi).
class _OptionSheet<T> extends StatelessWidget {
  const _OptionSheet({
    required this.title,
    required this.current,
    required this.options,
  });

  final String title;
  final T current;
  final Map<T, String> options;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: VigilantColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(title, style: text.headlineSmall?.copyWith(fontSize: 20)),
            const SizedBox(height: 12),
            for (final entry in options.entries)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  entry.key == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: entry.key == current
                      ? VigilantColors.primary
                      : VigilantColors.onSurfaceVariant,
                ),
                title: Text(entry.value, style: text.bodyMedium),
                onTap: () => Navigator.of(context).pop(entry.key),
              ),
          ],
        ),
      ),
    );
  }
}

/// "ÖĞRENME" bölümü: kaç segment süresinin öğrenildiğini ve ne işe yaradığını
/// gösterir — uygulamanın "öğrenen" tarafını kullanıcıya görünür kılar.
class _LearningSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final count = ref.watch(learnedSegmentCountProvider).valueOrNull ?? 0;
    final accuracy = ref.watch(predictionAccuracyProvider).valueOrNull ??
        PredictionAccuracy.empty;
    final settings =
        ref.watch(settingsProvider).valueOrNull ?? const AppSettings();
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 8),
            child: Text(
              'ÖĞRENME',
              style: text.labelLarge?.copyWith(
                color: VigilantColors.primary,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: VigilantColors.surfaceContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              VigilantColors.secondary.withValues(alpha: 0.15),
                        ),
                        child: const Icon(Icons.insights_outlined,
                            color: VigilantColors.secondary),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              count == 0
                                  ? 'Henüz öğrenme yok'
                                  : '$count durak arası süre öğrenildi',
                              style: text.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Her yolculukta gerçek durak süreleri öğrenilir; '
                              'yeraltında (sinyal yok) tahmin böylece iyileşir. '
                              'Veriler cihazında kalır.',
                              style: text.labelMedium?.copyWith(
                                color: VigilantColors.onSurfaceVariant,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
                // TAHMİN DOĞRULUĞU: kendi hatamızı ölçmeden "iyileşiyor"
                // demek boş bir iddia olurdu. Sayı kullanıcının kendi
                // yolculuklarından çıkar ve cihazında kalır.
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: VigilantColors.tertiaryContainer
                              .withValues(alpha: 0.15),
                        ),
                        child: const Icon(Icons.rule_rounded,
                            color: VigilantColors.tertiaryContainer),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              accuracy.samples == 0
                                  ? 'Tahmin doğruluğu ölçülmedi'
                                  : 'Tahmin sapması ortalama '
                                      '${(accuracy.meanAbsErrorSeconds / 60).toStringAsFixed(1)} dk',
                              style: text.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              accuracy.samples == 0
                                  ? 'Birkaç yolculuk tamamlayınca tahminlerin '
                                      'ne kadar tuttuğu burada görünecek.'
                                  : '${accuracy.samples} yolculuk ölçüldü · '
                                      '${accuracy.meanBiasSeconds >= 0 ? "tahminler kısa kalıyor" : "tahminler uzun kalıyor"} '
                                      '(${(accuracy.meanBiasSeconds.abs() / 60).toStringAsFixed(1)} dk)',
                              style: text.labelMedium?.copyWith(
                                color: VigilantColors.onSurfaceVariant,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
                // KVKK rızası: anonim kalabalık öğrenmeye katkı.
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Anonim katkı',
                                style: text.bodyMedium),
                            const SizedBox(height: 2),
                            Text(
                              'Durak sürelerini KİMLİĞİN olmadan ortak modele '
                              'gönder; herkesin tahmini iyileşsin. İstediğin an '
                              'kapatabilirsin.',
                              style: text.labelMedium?.copyWith(
                                color: VigilantColors.onSurfaceVariant,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: settings.contributeToCloud,
                        onChanged: (v) {
                          Haptics.selection();
                          ref
                              .read(settingsProvider.notifier)
                              .setContributeToCloud(v);
                        },
                      ),
                    ],
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

/// Varsayılan alarm tetikleyicisi seçim sayfası: mod (durak/mesafe) + eşik.
class _DefaultTriggerSheet extends StatefulWidget {
  const _DefaultTriggerSheet({
    required this.mode,
    required this.distanceIndex,
    required this.stopsIndex,
  });

  final int mode;
  final int distanceIndex;
  final int stopsIndex;

  @override
  State<_DefaultTriggerSheet> createState() => _DefaultTriggerSheetState();
}

class _DefaultTriggerSheetState extends State<_DefaultTriggerSheet> {
  late int _mode = widget.mode.clamp(0, 1);
  late final int _distanceIndex =
      widget.distanceIndex.clamp(0, AppSettings.distanceLabels.length - 1);
  late final int _stopsIndex =
      widget.stopsIndex.clamp(0, AppSettings.stopLabels.length - 1);

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final stopsMode = _mode == 0;
    final labels =
        stopsMode ? AppSettings.stopLabels : AppSettings.distanceLabels;
    final selected = stopsMode ? _stopsIndex : _distanceIndex;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: VigilantColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('Varsayılan Alarm',
                style: text.headlineSmall?.copyWith(fontSize: 20)),
            const SizedBox(height: 4),
            Text(
              'Yeni bir alarm kurarken bu değerle başlar.',
              style: text.labelMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            // Mod seçimi
            Container(
              height: 44,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: VigilantColors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  for (final (i, label) in const [
                    (0, 'Kalan Durak'),
                    (1, 'Kalan Mesafe'),
                  ])
                    Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _mode = i),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          alignment: Alignment.center,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: i == _mode
                                ? VigilantColors.primary
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            label,
                            style: text.labelLarge?.copyWith(
                              color: i == _mode
                                  ? VigilantColors.onPrimary
                                  : VigilantColors.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < labels.length; i++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  i == selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: i == selected
                      ? VigilantColors.primary
                      : VigilantColors.onSurfaceVariant,
                ),
                title: Text('${labels[i]} kala', style: text.bodyMedium),
                onTap: () => Navigator.of(context).pop((
                  mode: _mode,
                  distanceIndex: stopsMode ? _distanceIndex : i,
                  stopsIndex: stopsMode ? i : _stopsIndex,
                )),
              ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 8),
            child: Text(
              title,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: VigilantColors.primary,
                    letterSpacing: 1.2,
                  ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: VigilantColors.surfaceContainer,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i != children.length - 1)
                    Divider(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.05),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.trailing,
    this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: VigilantColors.onSurfaceVariant),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.bodyMedium),
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle!,
                        style: text.labelMedium?.copyWith(
                            color: VigilantColors.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// Alarm sesi seçici — her satırda DİNLE tuşu.
class _AlarmSoundSheet extends StatelessWidget {
  const _AlarmSoundSheet({required this.current});

  final String current;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: VigilantColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text('Alarm Sesi',
                style: text.headlineSmall?.copyWith(fontSize: 20)),
            const SizedBox(height: 12),
            for (final snd in AlarmSound.all)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  snd.label == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: snd.label == current
                      ? VigilantColors.primary
                      : VigilantColors.onSurfaceVariant,
                ),
                title: Text(snd.label, style: text.bodyMedium),
                subtitle: snd.hasOwnFile
                    ? null
                    : Text('kendi sesi henüz yok — varsayılan çalar',
                        style: text.labelSmall?.copyWith(
                            color: VigilantColors.onSurfaceVariant)),
                trailing: ValueListenableBuilder<String?>(
                  valueListenable: AlarmSoundPreview.playing,
                  builder: (context, playing, _) {
                    final on = playing == snd.label;
                    return IconButton(
                      tooltip: on ? 'Durdur' : 'Dinle',
                      icon: Icon(
                          on
                              ? Icons.stop_circle_outlined
                              : Icons.play_circle_outline,
                          color: VigilantColors.primary),
                      onPressed: () {
                        Haptics.light();
                        AlarmSoundPreview.toggle(snd);
                      },
                    );
                  },
                ),
                onTap: () => Navigator.of(context).pop(snd.label),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Yolculuk hatırlatması" anahtarı + son kaydedilen rota özeti.
///
/// Durumu SharedPreferences'ta (JourneyReminder); ayarlar modelinde değil —
/// bildirim zamanlaması arka plan izolatından da okunabilmeli.
class _ReminderTile extends StatefulWidget {
  const _ReminderTile();

  @override
  State<_ReminderTile> createState() => _ReminderTileState();
}

class _ReminderTileState extends State<_ReminderTile> {
  bool _enabled = true;
  String _summary = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final on = await JourneyReminder.isEnabled();
    final rec = await JourneyReminder.saved();
    if (!mounted) return;
    setState(() {
      _enabled = on;
      if (rec == null) {
        _summary = 'İlk alarmından sonra devreye girer';
      } else {
        final h = (rec['hour'] as num?)?.toInt() ?? 0;
        final m = (rec['minute'] as num?)?.toInt() ?? 0;
        final code = '${rec['lineCode'] ?? ''}';
        final to = '${rec['targetStopName'] ?? ''}';
        final saat =
            '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
        _summary = [saat, if (code.isNotEmpty) code, if (to.isNotEmpty) to]
            .join(' · ');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsTile(
      icon: Icons.alarm_add_outlined,
      title: 'Yolculuk hatırlatması',
      subtitle: _summary,
      trailing: Switch(
        value: _enabled,
        onChanged: (v) async {
          Haptics.selection();
          setState(() => _enabled = v);
          await JourneyReminder.setEnabled(v);
        },
      ),
    );
  }
}


/// "Bu hesaba giriş yapılsın mı?" — ikinci cihazda hesaba dönüş.
///
/// Düz bir uyarı kutusuydu; kullanıcının kayıtlı hayatını (favoriler, geçmiş,
/// ayarlar) geri getiren bir adım için fazla sönük duruyordu. Kazanılanı ve
/// kaybedileni AYRI AYRI göstermek kararı da kolaylaştırıyor.
class _SignInSheet extends StatelessWidget {
  const _SignInSheet();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
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
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: VigilantColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: VigilantColors.primary.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.account_circle_rounded,
                    size: 34, color: VigilantColors.primary),
              ),
            ),
            const SizedBox(height: 16),
            Text('Hesabına dön',
                textAlign: TextAlign.center,
                style: text.headlineSmall?.copyWith(fontSize: 22)),
            const SizedBox(height: 8),
            Text(
              'Bu Google hesabı zaten bir StopAlert kaydına bağlı. '
              'Giriş yaparsan o kayda dönersin.',
              textAlign: TextAlign.center,
              style: text.bodyMedium
                  ?.copyWith(color: VigilantColors.onSurfaceVariant),
            ),
            const SizedBox(height: 18),
            const _SheetRow(
              icon: Icons.cloud_download_rounded,
              color: VigilantColors.primary,
              title: 'Geri gelenler',
              detail: 'Favori rotaların, son aramaların, yolculuk geçmişin '
                  've profil ayarların',
            ),
            const SizedBox(height: 10),
            const _SheetRow(
              icon: Icons.info_outline_rounded,
              color: VigilantColors.tertiaryContainer,
              title: 'Bu cihazda kalanlar',
              detail: 'Şu anki anonim kayıttaki veriler o hesaba taşınmaz',
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: () {
                Haptics.light();
                Navigator.pop(context, true);
              },
              style: FilledButton.styleFrom(
                backgroundColor: VigilantColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
              ),
              child: const Text('Giriş yap',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Vazgeç',
                  style: TextStyle(color: VigilantColors.onSurfaceVariant)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Giriş sayfasındaki tek satırlık bilgi kutusu.
class _SheetRow extends StatelessWidget {
  const _SheetRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
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
                    style: text.labelSmall
                        ?.copyWith(color: VigilantColors.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
