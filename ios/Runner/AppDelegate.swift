import Flutter
import UIKit
import UserNotifications
import AlarmKit
import AppIntents
import CryptoKit
import SwiftUI
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var alarmChannel: FlutterMethodChannel?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    WorkmanagerPlugin.registerPeriodicTask(withIdentifier: "net.icycloud.fdtodolist.sync.refresh")
    WorkmanagerPlugin.registerBGProcessingTask(withIdentifier: "net.icycloud.fdtodolist.sync.processing")
    WorkmanagerPlugin.registerLaunchHandlers()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TodoAlarms") else { return }
    let channel = FlutterMethodChannel(
      name: "net.icycloud.fdtodolist/alarms", binaryMessenger: registrar.messenger())
    alarmChannel = channel
    channel.setMethodCallHandler { call, result in
      Task { @MainActor in
        if call.method == "initialize" {
          if !UserDefaults.standard.bool(forKey: "task_notifications_migrated") {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
            UserDefaults.standard.set(true, forKey: "task_notifications_migrated")
          }
          result(nil)
          return
        }
        if call.method == "notificationSnapshot" {
          result([])
          return
        }
        if call.method == "authorizeNotifications" || call.method == "synchronizeNotifications" {
          do {
            if call.method == "authorizeNotifications" {
              guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) else {
                result(FlutterError(code: "permission", message: "请在系统设置中允许高效Todo发送通知", details: nil))
                return
              }
            } else {
              try await self.synchronizeNotifications(call.arguments as? [[String: Any]] ?? [])
            }
            result(nil)
          } catch {
            result(FlutterError(code: "notification", message: error.localizedDescription, details: nil))
          }
          return
        }
        guard #available(iOS 26.0, *) else {
          if call.method == "status" { result(["authorized": false]); return }
          result(FlutterError(code: "unsupported", message: "系统闹钟需要 iOS 26 或更高版本", details: nil))
          return
        }
        do {
          switch call.method {
          case "authorize":
            guard try await AlarmManager.shared.requestAuthorization() == .authorized else {
              throw TodoAlarmError.permission
            }
            result(nil)
          case "status":
            result(["authorized": AlarmManager.shared.authorizationState == .authorized,
              "canRequest": AlarmManager.shared.authorizationState == .notDetermined])
          case "snapshot":
            result(TodoAlarmStore.shared.snapshot())
          case "synchronize":
            try await TodoAlarmStore.shared.synchronize(call.arguments as? [[String: Any]] ?? [])
            result(nil)
          default:
            result(FlutterMethodNotImplemented)
          }
        } catch {
          result(FlutterError(code: "alarm", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if notification.request.identifier.hasPrefix("task-notification-") {
      completionHandler([.banner, .list, .sound])
    } else {
      super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }
  }

  @MainActor
  private func synchronizeNotifications(_ desired: [[String: Any]]) async throws {
    let center = UNUserNotificationCenter.current()
    let prefix = "task-notification-"
    let existing = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix) }
    let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.identifier, $0) })
    var retained = Set<String>()
    for value in desired {
      guard let id = value["id"] as? String, let title = value["title"] as? String,
            let at = value["at"] as? NSNumber else { continue }
      let date = Date(timeIntervalSince1970: at.doubleValue)
      guard date > Date() else { continue }
      let identifier = prefix + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
      retained.insert(identifier)
      if byID[identifier]?.content.title == title { continue }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = "任务提醒"
      content.sound = .default
      let components = Calendar.current.dateComponents(in: .current, from: date)
      let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
      try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
    center.removePendingNotificationRequests(withIdentifiers: Set(byID.keys).subtracting(retained).map { $0 })
  }
}

@available(iOS 26.0, *)
private enum TodoAlarmError: LocalizedError {
  case permission
  var errorDescription: String? { "请在系统设置中允许高效Todo使用闹钟" }
}

@available(iOS 26.0, *)
struct TodoAlarmMetadata: AlarmMetadata {
  var title: String
}

@available(iOS 26.0, *)
private struct TodoAlarmEntry: Codable {
  let id: String
  let task: String
  let occurrence: Int
  let at: Int
  var title: String
  var nextAt: TimeInterval
  var dismissed: Bool

  var nativeID: UUID {
    let b = Array(SHA256.hash(data: Data(id.utf8)))
    return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
      b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
  }
  var json: [String: Any] {
    ["id": id, "task": task, "occurrence": occurrence, "at": at, "title": title]
  }
}

@available(iOS 26.0, *)
@MainActor
private final class TodoAlarmStore {
  static let shared = TodoAlarmStore()
  private let storageKey = "task_alarms_v1"
  private var entries: [String: TodoAlarmEntry]

  private init() {
    if let data = UserDefaults.standard.data(forKey: "task_alarms_v1"),
       let stored = try? JSONDecoder().decode([String: TodoAlarmEntry].self, from: data) {
      entries = stored
    } else { entries = [:] }
  }
  private func persist() throws {
    UserDefaults.standard.set(try JSONEncoder().encode(entries), forKey: storageKey)
  }
  func snapshot() -> [[String: Any]] {
    entries.values.filter { !$0.dismissed }.map { $0.json }
  }

  func synchronize(_ desired: [[String: Any]]) async throws {
    guard AlarmManager.shared.authorizationState == .authorized else { throw TodoAlarmError.permission }
    var updated: [String: TodoAlarmEntry] = [:]
    for value in desired {
      guard let id = value["id"] as? String,
            let task = value["task"] as? String,
            let occurrence = value["occurrence"] as? NSNumber,
            let at = value["at"] as? NSNumber,
            let title = value["title"] as? String else { continue }
      if var old = entries[id] {
        old.title = title
        updated[id] = old
      } else {
        updated[id] = TodoAlarmEntry(id: id, task: task, occurrence: occurrence.intValue,
          at: at.intValue, title: title, nextAt: at.doubleValue, dismissed: false)
      }
    }
    let existingIDs = Set(entries.keys)
    let removed = entries.values.filter { updated[$0.id] == nil }
    entries = updated
    try persist()
    for entry in removed { try? AlarmManager.shared.cancel(id: entry.nativeID) }
    for id in updated.keys {
      guard let entry = entries[id], !entry.dismissed else { continue }
      if try AlarmManager.shared.alarms.contains(where: { $0.id == entry.nativeID }) { continue }
      if existingIDs.contains(id) && entry.nextAt <= Date().timeIntervalSince1970 {
        // The stop or snooze intent may still be in transit; leave its state intact.
        continue
      }
      try await schedule(entry)
      // A stop action can execute while schedule awaits the system.
      if entries[entry.id]?.dismissed != false || entries[entry.id] == nil {
        try? AlarmManager.shared.cancel(id: entry.nativeID)
      }
    }
  }

  private func schedule(_ entry: TodoAlarmEntry) async throws {
    let stop = AlarmButton(text: "关闭", textColor: .white, systemImageName: "stop.fill")
    let later = AlarmButton(text: "10 分钟后再响", textColor: .white, systemImageName: "clock.arrow.circlepath")
    let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: entry.title),
      stopButton: stop, secondaryButton: later, secondaryButtonBehavior: .custom)
    let attributes = AlarmAttributes(presentation: AlarmPresentation(alert: alert),
      metadata: TodoAlarmMetadata(title: entry.title), tintColor: Color.blue)
    let configuration = AlarmManager.AlarmConfiguration(
      schedule: .fixed(Date(timeIntervalSince1970: max(entry.nextAt, Date().timeIntervalSince1970 + 1))),
      attributes: attributes, stopIntent: StopTodoAlarm(alarmID: entry.id),
      secondaryIntent: SnoozeTodoAlarm(alarmID: entry.id), sound: .default)
    _ = try await AlarmManager.shared.schedule(id: entry.nativeID, configuration: configuration)
  }

  func stop(_ id: String) throws {
    guard var entry = entries[id] else { return }
    entry.dismissed = true
    entries[id] = entry
    try persist()
    try? AlarmManager.shared.cancel(id: entry.nativeID)
  }

  func snooze(_ id: String) async throws {
    guard var entry = entries[id], !entry.dismissed else { return }
    entry.nextAt = Date().timeIntervalSince1970 + 600
    entries[id] = entry
    try persist()
    try? AlarmManager.shared.cancel(id: entry.nativeID)
    try await schedule(entry)
    if entries[id]?.dismissed != false { try? AlarmManager.shared.cancel(id: entry.nativeID) }
  }
}

@available(iOS 26.0, *)
struct StopTodoAlarm: LiveActivityIntent {
  static var title: LocalizedStringResource = "关闭任务闹钟"
  @Parameter(title: "闹钟标识") var alarmID: String
  init() {}
  init(alarmID: String) { self.alarmID = alarmID }
  @MainActor func perform() async throws -> some IntentResult {
    try TodoAlarmStore.shared.stop(alarmID)
    return .result()
  }
}

@available(iOS 26.0, *)
struct SnoozeTodoAlarm: LiveActivityIntent {
  static var title: LocalizedStringResource = "10 分钟后再响"
  @Parameter(title: "闹钟标识") var alarmID: String
  init() {}
  init(alarmID: String) { self.alarmID = alarmID }
  @MainActor func perform() async throws -> some IntentResult {
    try await TodoAlarmStore.shared.snooze(alarmID)
    return .result()
  }
}
