import Flutter
import Foundation
import UIKit

public final class PilotPlatformPlugin: NSObject, FlutterPlugin,
    UIAdaptivePresentationControllerDelegate {
  private var pendingExport: FlutterResult?
  private var pendingExportID: UUID?
  private var exportURL: URL?
  private var exportController: UIActivityViewController?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "farvahartrends/device", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(PilotPlatformPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if Thread.isMainThread {
      handleOnMain(call, result: result)
    } else {
      DispatchQueue.main.async { [weak self] in
        guard let self = self else {
          result(FlutterError(code: "unavailable", message: "Plugin is unavailable", details: nil))
          return
        }
        self.handleOnMain(call, result: result)
      }
    }
  }

  private func handleOnMain(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "state":
      result(deviceState())
    case "requestNotifications":
      // This pilot does not configure iOS push or claim background receiving.
      result(nil)
    case "batterySettings":
      openAppSettings(result: result)
    case "exportReport":
      exportReport(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func deviceState() -> [String: Any] {
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    let batteryLevel = device.batteryLevel
    let batteryPercent: Any
    if batteryLevel >= 0 {
      batteryPercent = Int((batteryLevel * 100).rounded())
    } else {
      batteryPercent = NSNull()
    }
    let charging: Any
    if device.batteryState == .unknown {
      charging = NSNull()
    } else {
      charging = device.batteryState == .charging || device.batteryState == .full
    }

    return [
      "platform": "ios",
      "manufacturer": "Apple",
      "model": device.model,
      "osVersion": device.systemVersion,
      "sdk": NSNull(),
      "targetSdk": NSNull(),
      "wallTimeMs": Int64(Date().timeIntervalSince1970 * 1000),
      // Never substitute wall time or infer Android-equivalent measurements.
      "elapsedRealtimeMs": NSNull(),
      "bootId": NSNull(),
      "isLocked": NSNull(),
      "lockStateKnown": false,
      // This means app-active, not physical display-on or device-unlocked.
      "screenOn": UIApplication.shared.applicationState == .active,
      "powerSave": ProcessInfo.processInfo.isLowPowerModeEnabled,
      "deviceIdle": NSNull(),
      "batteryExempt": NSNull(),
      "lowPowerStandby": NSNull(),
      "notificationsEnabled": NSNull(),
      "network": "unknown",
      "internetValidated": NSNull(),
      "batteryPercent": batteryPercent,
      "charging": charging,
      "addresses": [String]()
    ]
  }

  private func openAppSettings(result: @escaping FlutterResult) {
    guard UIApplication.shared.applicationState == .active,
      let url = URL(string: UIApplication.openSettingsURLString) else {
      result(FlutterError(code: "unavailable", message: "Open the app to open its settings", details: nil))
      return
    }
    // Called only in response to the Dart settings action. No exemption is implied.
    UIApplication.shared.open(url, options: [:]) { opened in
      if opened {
        result(nil)
      } else {
        result(FlutterError(code: "settings", message: "Could not open app settings", details: nil))
      }
    }
  }

  private func exportReport(_ arguments: Any?, result: @escaping FlutterResult) {
    guard pendingExport == nil else {
      result(FlutterError(code: "busy", message: "A report export is already open", details: nil))
      return
    }
    guard UIApplication.shared.applicationState == .active,
      let presenter = foregroundPresenter(), presenter.viewIfLoaded?.window != nil,
      !presenter.isBeingDismissed, presenter.transitionCoordinator == nil else {
      result(FlutterError(code: "unavailable", message: "Open the app to export a report", details: nil))
      return
    }
    guard let fields = arguments as? [String: Any], let report = fields["report"] as? String,
      let data = report.data(using: .utf8), !data.isEmpty, data.count <= 8_000_000 else {
      result(FlutterError(code: "size", message: "Report is empty or too large", details: nil))
      return
    }

    do {
      let json = try JSONSerialization.jsonObject(with: data, options: [])
      guard json is [String: Any] || json is [Any] else {
        result(FlutterError(code: "report", message: "Report must be a JSON object or array", details: nil))
        return
      }
      guard !containsPrivateKeyMaterial(json) else {
        result(FlutterError(code: "report", message: "Private key material cannot be exported", details: nil))
        return
      }

      let id = UUID()
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FarvaharTrends-test-\(id.uuidString).json")
      // Only the supplied report is written, in this application's temporary directory.
      try data.write(to: url, options: [.atomic, .completeFileProtection])
      pendingExport = result
      pendingExportID = id
      exportURL = url

      let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      exportController = controller
      controller.completionWithItemsHandler = { [weak self] _, completed, _, error in
        DispatchQueue.main.async {
          self?.finishExport(id: id, completed: completed, error: error)
        }
      }
      if let popover = controller.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(
          x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        popover.permittedArrowDirections = []
      }
      presenter.present(controller, animated: true)
      controller.presentationController?.delegate = self
    } catch {
      result(FlutterError(code: "export", message: "Could not prepare the JSON report", details: nil))
    }
  }

  private func foregroundPresenter() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
    guard let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }),
      let root = window.rootViewController else { return nil }
    return topController(root)
  }

  private func topController(_ controller: UIViewController) -> UIViewController {
    if let presented = controller.presentedViewController {
      return topController(presented)
    }
    if let navigation = controller as? UINavigationController,
      let visible = navigation.visibleViewController {
      return topController(visible)
    }
    if let tabs = controller as? UITabBarController, let selected = tabs.selectedViewController {
      return topController(selected)
    }
    return controller
  }

  public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard presentationController.presentedViewController === exportController,
      let id = pendingExportID else { return }
    finishExport(id: id, completed: false, error: nil)
  }

  private func finishExport(id: UUID, completed: Bool, error: Error?) {
    guard pendingExportID == id, let result = pendingExport else { return }
    pendingExport = nil
    pendingExportID = nil
    exportController = nil
    if let url = exportURL { try? FileManager.default.removeItem(at: url) }
    exportURL = nil
    if error != nil {
      result(FlutterError(code: "export", message: "Report sharing did not complete", details: nil))
    } else {
      // UIKit completion is user-selected share/save completion, not recipient delivery proof.
      result(completed)
    }
  }

  private func containsPrivateKeyMaterial(_ value: Any) -> Bool {
    if let fields = value as? [String: Any] {
      for (key, child) in fields {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        if normalized.contains("privatekey") || normalized == "secretkey"
          || normalized == "signingseed" || containsPrivateKeyMaterial(child) { return true }
      }
    } else if let items = value as? [Any] {
      return items.contains(where: containsPrivateKeyMaterial)
    } else if let text = value as? String {
      return text.contains("-----BEGIN") && text.contains("PRIVATE KEY-----")
    }
    return false
  }

  deinit {
    if let url = exportURL { try? FileManager.default.removeItem(at: url) }
  }
}
