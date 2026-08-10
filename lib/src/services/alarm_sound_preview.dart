import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../data/alarm_sound.dart';

/// Alarm sesi ÖNİZLEMESİ — kullanıcı seçmeden önce dinlesin.
///
/// Tek bir çalar kullanılır: arka arkaya iki sese dokunulduğunda ikisi üst
/// üste binmez, öncekini keser. Ses ALARM kanalından çalar ki telefonun
/// medya sesi kısıkken bile duyulsun — kullanıcının denediği şey zaten bir
/// alarm.
abstract final class AlarmSoundPreview {
  static final _player = AudioPlayer();

  /// ŞU AN çalan sesin etiketi (yoksa null).
  ///
  /// Arayüz buna bakıp oynat tuşunu DURDUR'a çeviriyor: alarm sesleri uzun
  /// ve tekrarlı, kullanıcıyı sesin kendiliğinden bitmesini beklemeye
  /// zorlamak yanlıştı.
  static final ValueNotifier<String?> playing = ValueNotifier<String?>(null);

  static bool _wired = false;

  /// Ses kendiliğinden bittiğinde tuş eski hâline dönmeli.
  static void _wire() {
    if (_wired) return;
    _wired = true;
    _player.onPlayerComplete.listen((_) => playing.value = null);
  }

  static Future<void> play(AlarmSound sound) async {
    try {
      _wire();
      await _player.stop();
      playing.value = sound.label;
      await _player.setAudioContext(
        AudioContext(
          android: const AudioContextAndroid(
            contentType: AndroidContentType.sonification,
            usageType: AndroidUsageType.alarm,
            audioFocus: AndroidAudioFocus.gainTransientMayDuck,
          ),
          iOS: AudioContextIOS(
            category: AVAudioSessionCategory.playback,
            options: const {AVAudioSessionOptions.duckOthers},
          ),
        ),
      );
      await _player.play(AssetSource(sound.assetPath));
    } catch (_) {
      // Ses çalınamazsa sessizce geç: önizleme kritik bir akış değil.
      playing.value = null;
    }
  }

  /// Çalıyorsa durdur, değilse çal.
  static Future<void> toggle(AlarmSound sound) async {
    if (playing.value == sound.label) return stop();
    return play(sound);
  }

  static Future<void> stop() async {
    playing.value = null;
    try {
      await _player.stop();
    } catch (_) {}
  }
}
