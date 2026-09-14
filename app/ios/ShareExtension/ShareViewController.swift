//
//  ShareViewController.swift
//  ShareExtension
//
//  「发送到家账」分享扩展。
//  刻意不继承 SLComposeServiceViewController：不弹编辑框，读到内容就写入 App Group 并唤起主 App。
//
//  注意：本文件属于 ShareExtension target，与主 App（Runner）不共享代码，
//  因此这里的 App Group 读写逻辑与 Runner/AppDelegate.swift 里的 PendingShareStore 是「有意重复」的一份。
//  两边的常量（App Group id、key、上限、字段名）以及 URL 契约必须保持一致。
//

import ImageIO
import UIKit
import Vision

// MARK: - 与主 App / Dart 侧的契约
// 改动这里需同步：Runner/AppDelegate.swift（PendingShareStore）、Runner/ShortcutIntents.swift、
// lib/platform/share_import.dart。

private let famAppGroupId = "group.com.famledger.app"
private let famPendingKey = "pendingShares"
private let famMaxPending = 20
private let famSource = "share"

/// App Group 不可用时的兜底：把文本直接塞进深链。超过该长度则截断。
private let famMaxURLTextLength = 1500

private let famTypeText = "public.plain-text"
private let famTypeURL = "public.url"
private let famTypeImage = "public.image"

/// 读取分享内容 → 写 App Group → 打开 famledger://capture 的整体超时保护。
private let famWatchdogSeconds: TimeInterval = 12

class ShareViewController: UIViewController {

    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var didFinish = false
    /// 已进入关闭流程（失败提示 / 已唤起主 App），此后忽略迟到的回调。
    private var isClosing = false

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        startWatchdog()

        collectSharedText { [weak self] text in
            guard let self = self else { return }
            let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // 即使已经超时关闭，迟到的内容也要写进 App Group（只是不再更新 UI、不再唤起主 App），
            // 用户下次打开主 App 时仍然能被 takePending() 消费掉。
            let stored = trimmed.isEmpty
                ? false
                : appendPendingShare(text: trimmed, source: famSource)
            guard !self.isClosing else { return }
            if trimmed.isEmpty {
                self.showFailureAndClose()
                return
            }
            self.openHostAppAndClose(text: trimmed, storedInAppGroup: stored)
        }
    }

    // MARK: - 界面

    private func setupUI() {
        view.backgroundColor = .systemBackground

        statusLabel.text = "正在发送到家账…"
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.textColor = .label
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
    }

    private func startWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + famWatchdogSeconds) { [weak self] in
            guard let self = self, !self.isClosing else { return }
            self.showFailureAndClose()
        }
    }

    private func showFailureAndClose() {
        isClosing = true
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.text = "无法读取内容"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.finish()
        }
    }

    // MARK: - 读取分享内容

    /// 遍历所有 NSItemProvider，按原顺序把能识别的文本拼起来。
    private func collectSharedText(completion: @escaping (String?) -> Void) {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var pieces: [Int: String] = [:]

        for (index, provider) in providers.enumerated() {
            group.enter()
            var finished = false
            load(provider: provider) { piece in
                // 防止某些 provider 多次回调导致 leave 过多而崩溃。
                guard !finished else { return }
                finished = true
                if let piece = piece,
                   !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    lock.lock()
                    pieces[index] = piece
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let ordered = pieces.keys.sorted().compactMap { pieces[$0] }
            completion(ordered.isEmpty ? nil : ordered.joined(separator: "\n"))
        }
    }

    private func load(provider: NSItemProvider, completion: @escaping (String?) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(famTypeText) {
            provider.loadItem(forTypeIdentifier: famTypeText, options: nil) { item, _ in
                completion(famString(fromItem: item))
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(famTypeURL) {
            provider.loadItem(forTypeIdentifier: famTypeURL, options: nil) { item, _ in
                if let url = item as? URL {
                    completion(url.absoluteString)
                } else {
                    completion(famString(fromItem: item))
                }
            }
            return
        }
        if provider.hasItemConformingToTypeIdentifier(famTypeImage) {
            provider.loadItem(forTypeIdentifier: famTypeImage, options: nil) { item, _ in
                guard let image = famImage(fromItem: item) else {
                    completion(nil)
                    return
                }
                famRecognizeText(in: image, completion: completion)
            }
            return
        }
        completion(nil)
    }

    // MARK: - 唤起主 App

    private func openHostAppAndClose(text: String, storedInAppGroup: Bool) {
        isClosing = true
        guard let url = famCaptureURL(text: text, storedInAppGroup: storedInAppGroup) else {
            finish()
            return
        }
        // UIApplication 在扩展里不可用：沿 responder chain 找到能响应 openURL: 的对象。
        if openViaResponderChain(url) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.finish()
            }
            return
        }
        extensionContext?.open(url) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self?.finish()
            }
        }
    }

    private func openViaResponderChain(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self.next
        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

// MARK: - 工具函数

/// `famledger://capture?source=share[&text=...]`
///
/// - 文本不超过 `famMaxURLTextLength` → **总是**带上 `text=`（Dart 侧以 URL 里的为准，深链本身就是完整内容）；
/// - 超长但已写进 App Group → 不带 `text=`，主 App 用 `takePending()` 取完整内容；
/// - 超长且没能写进 App Group（例如免费个人证书不支持 App Groups）→ 截断后带上，有损总好过全丢。
private func famCaptureURL(text: String, storedInAppGroup: Bool) -> URL? {
    var query = "source=\(famSource)"
    var payload: String?
    if text.count <= famMaxURLTextLength {
        payload = text
    } else if !storedInAppGroup {
        payload = String(text.prefix(famMaxURLTextLength))
    }
    if let payload = payload, !payload.isEmpty {
        // URLComponents 不会转义 "+"，而 Dart 的 Uri.queryParameters 会把 "+" 解成空格，这里手工转义。
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?#"))
        if let encoded = payload.addingPercentEncoding(withAllowedCharacters: allowed) {
            query += "&text=\(encoded)"
        }
    }
    return URL(string: "famledger://capture?\(query)")
}

private func famString(fromItem item: NSSecureCoding?) -> String? {
    if let text = item as? String { return text }
    if let attributed = item as? NSAttributedString { return attributed.string }
    if let url = item as? URL { return url.absoluteString }
    if let data = item as? Data { return String(data: data, encoding: .utf8) }
    return nil
}

private func famImage(fromItem item: NSSecureCoding?) -> UIImage? {
    if let image = item as? UIImage { return image }
    if let url = item as? URL, let data = try? Data(contentsOf: url) { return UIImage(data: data) }
    if let data = item as? Data { return UIImage(data: data) }
    return nil
}

/// Vision OCR：中文 + 英文。注意 zh-Hans 需要 iOS 14+（Vision revision 2），
/// iOS 13 上只会识别英文，不会报错。
private func famRecognizeText(in image: UIImage, completion: @escaping (String?) -> Void) {
    guard let cgImage = image.cgImage else {
        completion(nil)
        return
    }
    let orientation = famCGOrientation(from: image.imageOrientation)
    DispatchQueue.global(qos: .userInitiated).async {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            completion(nil)
            return
        }
        let observations = request.results as? [VNRecognizedTextObservation] ?? []
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")
        completion(text.isEmpty ? nil : text)
    }
}

private func famCGOrientation(from orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
    switch orientation {
    case .up: return .up
    case .upMirrored: return .upMirrored
    case .down: return .down
    case .downMirrored: return .downMirrored
    case .left: return .left
    case .leftMirrored: return .leftMirrored
    case .right: return .right
    case .rightMirrored: return .rightMirrored
    @unknown default: return .up
    }
}

// MARK: - App Group 存储（与 Runner 的 PendingShareStore 等价）

/// App Group 是否真的可用。
///
/// 注意：`UserDefaults(suiteName:)` **即使没有 App Group 权限也会返回对象**，写完在同进程内还能读回来，
/// 所以不能用「写完读回」来探测，必须问容器目录在不在。
private func famAppGroupAvailable() -> Bool {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: famAppGroupId) != nil
}

/// 追加一条待处理分享；返回是否写入成功。
private func appendPendingShare(text: String, source: String) -> Bool {
    guard famAppGroupAvailable(), let defaults = UserDefaults(suiteName: famAppGroupId) else { return false }
    var items = readPendingShares(from: defaults)
    items.append([
        "text": text,
        "source": source,
        "receivedAt": ISO8601DateFormatter().string(from: Date()),
    ])
    if items.count > famMaxPending {
        items.removeFirst(items.count - famMaxPending)
    }
    guard JSONSerialization.isValidJSONObject(items),
          let data = try? JSONSerialization.data(withJSONObject: items, options: []),
          let json = String(data: data, encoding: .utf8) else {
        return false
    }
    defaults.set(json, forKey: famPendingKey)
    return true
}

private func readPendingShares(from defaults: UserDefaults) -> [[String: Any]] {
    if let json = defaults.string(forKey: famPendingKey),
       let data = json.data(using: .utf8) {
        let parsed = try? JSONSerialization.jsonObject(with: data, options: [])
        if let array = parsed as? [[String: Any]] { return array }
    }
    if let legacy = defaults.array(forKey: famPendingKey) as? [[String: Any]] {
        return legacy
    }
    return []
}
