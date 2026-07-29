import 'package:flutter/material.dart';

/// Stopi'nin gösterdiği küçük bağlam-duyarlı ipucu (metin + ikon).
class StopiTip {
  const StopiTip(this.text, this.icon);
  final String text;
  final IconData icon;
}

/// Zamana, havaya ve kullanıcı durumuna göre tek bir ipucu seçer (saf).
abstract final class StopiTips {
  static StopiTip pick({
    String? weatherLabel,
    required int hour,
    required bool hasFavorites,
    required bool hasJourneys,
    int seed = 0,
  }) {
    if (weatherLabel == 'Yağmurlu' || weatherLabel == 'Sağanak') {
      return const StopiTip(
          'Yağmur var — şemsiyeni al, durağını kaçırma.', Icons.umbrella_rounded);
    }
    if (weatherLabel == 'Karlı') {
      return const StopiTip(
          'Kar var; yollar yavaşlayabilir, biraz erken çık.', Icons.ac_unit_rounded);
    }
    if (weatherLabel == 'Fırtına') {
      return const StopiTip('Hava sert — güvenli yolculuklar.', Icons.bolt_rounded);
    }
    if (hour >= 7 && hour <= 9) {
      return const StopiTip(
          'Sabah yoğunluğu — Marmaray kalabalık olabilir.', Icons.groups_rounded);
    }
    if (hour >= 17 && hour <= 19) {
      return const StopiTip(
          'Akşam saatleri yoğun; alarmını erkenden kur.', Icons.schedule_rounded);
    }
    if (!hasJourneys) {
      return const StopiTip('İlk yolculuğunu kur — durağını asla kaçırma.',
          Icons.tips_and_updates_rounded);
    }
    const pool = [
      StopiTip('Alarm kurmayı unutma; ben seni uyandırırım.',
          Icons.notifications_active_rounded),
      StopiTip('Yeraltında bile takip ederim — sinyal gitse de.',
          Icons.wifi_off_rounded),
      StopiTip('Sık gittiğin rotayı favorilere ekle, tek dokunuşla başlat.',
          Icons.star_rounded),
      StopiTip('İnmene yaklaşınca ekranın yanar, alarm çalar.',
          Icons.alarm_rounded),
    ];
    if (hasFavorites) {
      return const StopiTip('Favori rotanı tek dokunuşla başlatabilirsin.',
          Icons.star_rounded);
    }
    return pool[seed % pool.length];
  }
}
