import UIKit
import UniformTypeIdentifiers

/// 分享面板里的「导入到PDF投屏」：把分到的 PDF 拷进 App Group 共享容器，
/// 再尝试唤起主 App（pdfcast://）。主 App 在启动/回前台时从共享容器拉取，
/// 所以即使唤起被系统拦下，文件也不会丢。
class ShareViewController: UIViewController {
  private let groupId = "group.com.weavejam.pdfcast"

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    processAttachments()
  }

  private func processAttachments() {
    let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
      .flatMap { $0.attachments ?? [] } ?? []
    let pdfType = UTType.pdf.identifier
    let pdfs = providers.filter { $0.hasItemConformingToTypeIdentifier(pdfType) }
    guard !pdfs.isEmpty else { finish(); return }
    let waits = DispatchGroup()
    for p in pdfs {
      waits.enter()
      p.loadFileRepresentation(forTypeIdentifier: pdfType) { url, _ in
        // 回调返回后系统会删掉临时文件，必须在回调内同步拷走
        defer { waits.leave() }
        guard let url else { return }
        self.copyToInbox(url)
      }
    }
    waits.notify(queue: .main) {
      self.openMainApp()
      self.finish()
    }
  }

  private func copyToInbox(_ url: URL) {
    guard let container = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: groupId) else { return }
    let inbox = container.appendingPathComponent("Inbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    let dest = inbox.appendingPathComponent(
      "\(Int(Date().timeIntervalSince1970 * 1000))-\(url.lastPathComponent)")
    try? FileManager.default.copyItem(at: url, to: dest)
  }

  /// extension 不允许直接 UIApplication.shared.open，沿 responder 链找宿主的 openURL:
  private func openMainApp() {
    guard let url = URL(string: "pdfcast://import") else { return }
    let selector = NSSelectorFromString("openURL:")
    var responder: UIResponder? = self
    while let r = responder {
      if r.responds(to: selector), !(r is UIViewController) {
        r.perform(selector, with: url)
        return
      }
      responder = r.next
    }
  }

  private func finish() {
    extensionContext?.completeRequest(returningItems: nil)
  }
}
