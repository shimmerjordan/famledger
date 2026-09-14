//
//  ShortcutIntents.swift
//  Runner
//
//  快捷指令 / Siri：「记一笔」。需要 iOS 16+（AppIntents 框架）。
//  本文件属于 Runner target，直接复用 AppDelegate.swift 里的 PendingShareStore。
//

import Foundation

#if canImport(AppIntents)
import AppIntents

@available(iOS 16.0, *)
struct RecordTransactionIntent: AppIntent {
  static var title: LocalizedStringResource = "记一笔"

  static var description: IntentDescription? = IntentDescription(
    "把一段文字（支付通知、账单短信、随手记的内容）发送到家账，打开 App 后确认。"
  )

  /// 运行后打开主 App，让 Dart 侧读取待处理内容并跑解析管线。
  static var openAppWhenRun: Bool = true

  @Parameter(title: "内容")
  var text: String

  static var parameterSummary: some ParameterSummary {
    Summary("把 \(\.$text) 记到家账")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard PendingShareStore.append(text: text, source: "shortcut") else {
      // 典型原因：免费个人证书不支持 App Groups，容器不存在。这条路没有深链兜底，必须如实报错。
      return .result(dialog: "保存失败，请检查 App Group 配置")
    }
    return .result(dialog: "已发送到家账，请打开 App 确认")
  }
}

/// ⚠️ 用的是 4 参 `AppShortcut(intent:phrases:shortTitle:systemImageName:)`，这个初始化器是 **iOS 16.4+**
/// （Xcode 14.3 / iOS 16.4 SDK 才有），所以整个 provider 标 16.4；`RecordTransactionIntent` 本身仍是 16.0。
@available(iOS 16.4, *)
struct FamledgerAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: RecordTransactionIntent(),
      phrases: [
        "用\(.applicationName)记一笔",
        "\(.applicationName)记一笔",
      ],
      shortTitle: "记一笔",
      systemImageName: "square.and.pencil"
    )
  }
}
#endif
