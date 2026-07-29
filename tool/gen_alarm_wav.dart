// Alarm sesi üretici — telifsiz, sentezlenmiş iki tonlu siren.
//
// Çıktı: android/app/src/main/res/raw/stopalert_alarm.wav
// Bildirimde FLAG_INSISTENT ile kullanılır; ses, kullanıcı alarmı kapatana
// kadar döngüde çalar.
//
// Kullanım: dart run tool/gen_alarm_wav.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

void main() {
  const sampleRate = 44100;
  const seconds = 3.0;
  final total = (sampleRate * seconds).round();
  final samples = Int16List(total);

  // Desen: 0.35 sn 880 Hz + 0.35 sn 1245 Hz (yükselen ikili), 0.15 sn sessiz.
  const toneLen = 0.35;
  const gapLen = 0.15;
  const cycle = toneLen * 2 + gapLen;

  for (var i = 0; i < total; i++) {
    final t = i / sampleRate;
    final tc = t % cycle;
    double freq;
    double envelope;
    if (tc < toneLen) {
      freq = 880;
      envelope = _env(tc, toneLen);
    } else if (tc < toneLen * 2) {
      freq = 1244.5;
      envelope = _env(tc - toneLen, toneLen);
    } else {
      samples[i] = 0;
      continue;
    }
    // Kare dalgaya yaklaşan keskin ses (dikkat çekici) + hafif harmonik.
    final s = math.sin(2 * math.pi * freq * t) +
        0.35 * math.sin(2 * math.pi * freq * 3 * t);
    samples[i] = (s / 1.35 * envelope * 32000).round().clamp(-32767, 32767);
  }

  final wav = _wavBytes(samples, sampleRate);
  final out = File('android/app/src/main/res/raw/stopalert_alarm.wav');
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(wav);
  stdout.writeln('Üretildi: ${out.path} (${wav.length} bayt, ${seconds}s)');
}

/// Tık sesini önlemek için 8 ms giriş/çıkış rampası.
double _env(double t, double len) {
  const ramp = 0.008;
  if (t < ramp) return t / ramp;
  if (t > len - ramp) return (len - t) / ramp;
  return 1;
}

Uint8List _wavBytes(Int16List samples, int sampleRate) {
  final dataLen = samples.length * 2;
  final b = BytesBuilder();
  void str(String s) => b.add(s.codeUnits);
  void u32(int v) => b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
  void u16(int v) => b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));

  str('RIFF');
  u32(36 + dataLen);
  str('WAVE');
  str('fmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(sampleRate);
  u32(sampleRate * 2); // byte rate
  u16(2); // block align
  u16(16); // bits
  str('data');
  u32(dataLen);
  b.add(samples.buffer.asUint8List());
  return b.toBytes();
}
