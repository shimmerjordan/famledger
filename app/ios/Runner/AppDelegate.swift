import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  /// 与 lib/platform/share_import.dart 约定的通道名。
  private static let shareChannelName = "com.famledger/share"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    registerShareChannel()
    // 深链（famledger://capture?...）由 app_links 插件自行处理，这里不要重复实现
    // application(_:open:options:)，否则会收到两次。
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func registerShareChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      NSLog("[famledger] rootViewController 不是 FlutterViewController，com.famledger/share 未注册")
      return
    }
    let channel = FlutterMethodChannel(
      name: AppDelegate.shareChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "takePending":
        result(PendingShareStore.take())
      case "peekPending":
        result(PendingShareStore.peek())
      case "clearPending":
        PendingShareStore.clear()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// App Group 里「待处理分享」的读写。
///
/// 写入方：ShareExtension（另一个 target，代码在 ios/ShareExtension/ShareViewController.swift，
/// 是等价的重复实现）、快捷指令（ios/Runner/ShortcutIntents.swift，与本文件同 target，直接复用）。
/// 读取方：Dart（MethodChannel `com.famledger/share`）。
///
/// 存储格式：`pendingShares` = JSON 数组字符串，元素形如
/// `{"text": "...", "source": "share|shortcut", "receivedAt": "2026-09-13T12:00:00Z"}`；
/// 最多保留 20 条（超出丢弃最旧的）。通道返回的是解析后的数组，Dart 侧直接当 List<Map> 用。
enum PendingShareStore {
  static let appGroupId = "group.com.famledger.app"
  static let pendingKey = "pendingShares"
  static let maxPending = 20

  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupId)
  }

  /// App Group 是否真的可用。
  ///
  /// 注意：`UserDefaults(suiteName:)` **即使没有 App Group 权限也会返回对象**，同进程里写完还能读回来，
  /// 所以不能用「写完读回」来探测，必须问容器目录在不在（免费个人证书不支持 App Groups → 这里为 nil）。
  static var isAvailable: Bool {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) != nil
  }

  /// 读取但不清空。
  static func peek() -> [[String: Any]] {
    guard let defaults = defaults else { return [] }
    return read(from: defaults)
  }

  /// 读取并清空（主 App 消费后调用）。
  static func take() -> [[String: Any]] {
    guard let defaults = defaults else { return [] }
    let items = read(from: defaults)
    if !items.isEmpty {
      defaults.removeObject(forKey: pendingKey)
    }
    return items
  }

  static func clear() {
    defaults?.removeObject(forKey: pendingKey)
  }

  /// 追加一条；返回是否写入成功。
  @discardableResult
  static func append(text: String, source: String) -> Bool {
    guard isAvailable, let defaults = defaults else { return false }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    var items = read(from: defaults)
    items.append([
      "text": trimmed,
      "source": source,
      "receivedAt": ISO8601DateFormatter().string(from: Date()),
    ])
    if items.count > maxPending {
      items.removeFirst(items.count - maxPending)
    }
    return write(items, to: defaults)
  }

  private static func read(from defaults: UserDefaults) -> [[String: Any]] {
    if let json = defaults.string(forKey: pendingKey),
       let data = json.data(using: .utf8) {
      let parsed = try? JSONSerialization.jsonObject(with: data, options: [])
      if let array = parsed as? [[String: Any]] { return array }
    }
    // 兜底：兼容以原生数组写入的情况。
    if let legacy = defaults.array(forKey: pendingKey) as? [[String: Any]] {
      return legacy
    }
    return []
  }

  private static func write(_ items: [[String: Any]], to defaults: UserDefaults) -> Bool {
    guard JSONSerialization.isValidJSONObject(items),
          let data = try? JSONSerialization.data(withJSONObject: items, options: []),
          let json = String(data: data, encoding: .utf8) else {
      return false
    }
    defaults.set(json, forKey: pendingKey)
    return true
  }
}
