// StopAlert — iOS Live Activity (kilit ekranı + Dynamic Island)
//
// Bu dosyayı Xcode'da bir WIDGET EXTENSION target'ına ekle (bkz.
// LIVE_ACTIVITY_SETUP.md). Runner ve bu extension AYNI App Group'u
// paylaşmalı: group.com.originstudios.stopalert.liveactivity
//
// Veri, live_activities paketi tarafından App Group'taki paylaşılan
// UserDefaults'a "<attributes.id>_<anahtar>" biçiminde yazılır. Anahtarlar
// Dart'taki LiveActivityService._data ile birebir aynıdır:
//   lineCode, lineColor(#RRGGBB), targetStop, stopsRemaining, nextStop,
//   etaMinutes, state (active|approaching|signalLost|arrived|waiting)

import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Attributes (live_activities paketiyle uyumlu; ContentState boş)

struct LiveActivitiesAppAttributes: ActivityAttributes, Identifiable {
  public typealias LiveDeliveryData = ContentState
  public struct ContentState: Codable, Hashable {}
  var id = UUID()
}

// App Group — Dart tarafındaki LiveActivityService.appGroupId ile AYNI olmalı.
let sharedDefault = UserDefaults(
  suiteName: "group.com.originstudios.stopalert.liveactivity")!

// MARK: - Yardımcılar

extension Color {
  init(hex: String) {
    let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    var rgb: UInt64 = 0
    Scanner(string: s).scanHexInt64(&rgb)
    self.init(
      .sRGB,
      red: Double((rgb >> 16) & 0xFF) / 255,
      green: Double((rgb >> 8) & 0xFF) / 255,
      blue: Double(rgb & 0xFF) / 255,
      opacity: 1)
  }
}

struct JourneyData {
  let lineCode: String
  let lineColor: Color
  let targetStop: String
  let stopsRemaining: Int
  let nextStop: String
  let etaMinutes: Int
  let state: String

  var isSignalLost: Bool { state == "signalLost" }
  var isApproaching: Bool { state == "approaching" }
  var isArrived: Bool { state == "arrived" }

  // Anahtarlar "<attributes.id>_<key>" önekiyle okunur.
  static func load(_ attributes: LiveActivitiesAppAttributes) -> JourneyData {
    let p = "\(attributes.id)"
    let d = sharedDefault
    return JourneyData(
      lineCode: d.string(forKey: "\(p)_lineCode") ?? "",
      lineColor: Color(hex: d.string(forKey: "\(p)_lineColor") ?? "#FF453A"),
      targetStop: d.string(forKey: "\(p)_targetStop") ?? "",
      stopsRemaining: d.integer(forKey: "\(p)_stopsRemaining"),
      nextStop: d.string(forKey: "\(p)_nextStop") ?? "",
      etaMinutes: d.integer(forKey: "\(p)_etaMinutes"),
      state: d.string(forKey: "\(p)_state") ?? "active")
  }
}

// MARK: - Kilit ekranı kartı

struct LockScreenView: View {
  let j: JourneyData

  var body: some View {
    HStack(spacing: 14) {
      // Kalan durak halkası
      ZStack {
        Circle().stroke(j.lineColor.opacity(0.25), lineWidth: 5)
        VStack(spacing: 0) {
          Text(j.isArrived ? "✓" : "\(j.stopsRemaining)")
            .font(.system(size: 24, weight: .bold))
          if !j.isArrived {
            Text("durak").font(.system(size: 9, weight: .semibold))
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(width: 58, height: 58)
      .foregroundStyle(j.lineColor)

      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(j.lineCode).font(.caption.bold()).foregroundStyle(j.lineColor)
          Spacer()
          if j.isSignalLost {
            Label("Sinyal yok", systemImage: "wifi.slash")
              .font(.caption2).foregroundStyle(.orange)
          } else if j.isApproaching {
            Label("Hazırlan", systemImage: "bell.fill")
              .font(.caption2).foregroundStyle(j.lineColor)
          }
        }
        Text(j.isArrived ? "İndin: \(j.targetStop)" : j.targetStop)
          .font(.headline).lineLimit(1)
        if !j.isArrived {
          Text("Sonraki: \(j.nextStop) · ~\(j.etaMinutes) dk")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
          Text("İyi yolculuklar!").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
}

// MARK: - Widget (Live Activity + Dynamic Island)

struct StopAlertLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
      LockScreenView(j: JourneyData.load(context.attributes))
        .padding(14)
        .activityBackgroundTint(Color.black.opacity(0.9))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      let j = JourneyData.load(context.attributes)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Label(j.lineCode, systemImage: "tram.fill")
            .font(.caption.bold()).foregroundStyle(j.lineColor)
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(j.isArrived ? "Vardın" : "\(j.stopsRemaining) durak")
            .font(.headline).foregroundStyle(j.lineColor)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(
            j.isSignalLost
              ? "Sinyal yok · tahmini takip"
              : (j.isArrived
                ? j.targetStop
                : "Sonraki: \(j.nextStop) · ~\(j.etaMinutes) dk")
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      } compactLeading: {
        Image(systemName: "tram.fill").foregroundStyle(j.lineColor)
      } compactTrailing: {
        Text(j.isArrived ? "✓" : "\(j.stopsRemaining)")
          .foregroundStyle(j.lineColor)
      } minimal: {
        Text(j.isArrived ? "✓" : "\(j.stopsRemaining)")
          .foregroundStyle(j.lineColor)
      }
    }
  }
}

// MARK: - Widget Bundle (extension giriş noktası)

@main
struct StopAlertWidgetBundle: WidgetBundle {
  var body: some Widget {
    StopAlertLiveActivity()
  }
}
