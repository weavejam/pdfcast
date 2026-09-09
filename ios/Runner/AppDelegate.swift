import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var channel: FlutterMethodChannel?
  // 冷启动时 Flutter 还没起来，先缓存路径，等 Dart 调 getInitialPdf 取走
  private var pendingPdfPath: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let ch = FlutterMethodChannel(name: "pdfcast/share", binaryMessenger: controller.binaryMessenger)
      ch.setMethodCallHandler { [weak self] call, result in
        if call.method == "getInitialPdf" {
          result(self?.pendingPdfPath)
          self?.pendingPdfPath = nil
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
      channel = ch
    }
    if let url = launchOptions?[.url] as? URL {
      pendingPdfPath = importedPath(from: url)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // 其他 App「用 PDF投屏 打开 / 分享」文件时走这里（LSSupportsOpeningDocumentsInPlace=false，
  // 系统已把文件拷到 Documents/Inbox，我们再挪去 tmp 交给 Dart 处理）
  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    guard let path = importedPath(from: url) else { return false }
    if let ch = channel {
      ch.invokeMethod("onPdf", arguments: path)
    } else {
      pendingPdfPath = path
    }
    return true
  }

  private func importedPath(from url: URL) -> String? {
    guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return nil }
    let needsScoped = url.startAccessingSecurityScopedResource()
    defer { if needsScoped { url.stopAccessingSecurityScopedResource() } }
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("shared-\(Int(Date().timeIntervalSince1970))-\(url.lastPathComponent)")
    do {
      try? FileManager.default.removeItem(at: tmp)
      try FileManager.default.copyItem(at: url, to: tmp)
      // Inbox 里的原件用完即清，避免越积越多
      if url.path.contains("/Documents/Inbox/") {
        try? FileManager.default.removeItem(at: url)
      }
      return tmp.path
    } catch {
      return nil
    }
  }
}
