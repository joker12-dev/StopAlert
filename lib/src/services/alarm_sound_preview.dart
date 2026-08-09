import 'package:audioplayers/audioplayers.dart';

import '../data/alarm_sound.dart';

/// Alarm sesi ÖNİZLEMESİ — kullanıcı seçmeden önce dinlesin.
///
/// Tek bir çalar kullanılır: arka arkaya iki sese dokunulduğunda ikisi üst
/// üste binmez, öncekini keser. Ses ALARM kanalından çalar ki telefonun
/// medya sesi kısıkken bile duyulsun — kullanıcının denediği şey zaten bir
/// alarm.
abstract final class AlarmSoundPreview {
  static final _player = AudioPlayer();

  static Future<void> play(AlarmSound sound) async {
    try {
      await _player.stop();
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
    }
  }

  static Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {}
  }
}
