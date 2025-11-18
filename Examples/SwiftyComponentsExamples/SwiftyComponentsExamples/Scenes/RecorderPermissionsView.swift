import SwiftUI
import AVFoundation

#if os(macOS)
import CoreGraphics
import AppKit
#endif

/// 简单的录制权限检查页面。
///
/// 目标：让非技术用户在一个页面里完成「屏幕录制 / 麦克风 / 摄像头」三项权限的检查与申请。
struct RecorderPermissionsView: View {
    private enum PermissionStatus {
        case unknown
        case granted
        case denied

        var label: String {
            switch self {
            case .unknown: return String(localized: "Permissions.Status.Unknown")
            case .granted: return String(localized: "Permissions.Status.Granted")
            case .denied: return String(localized: "Permissions.Status.Denied")
            }
        }

        var color: Color {
            switch self {
            case .unknown: return .gray
            case .granted: return .green
            case .denied: return .red
            }
        }
    }

    @State private var screenStatus: PermissionStatus = .unknown
    @State private var micStatus: PermissionStatus = .unknown
    @State private var cameraStatus: PermissionStatus = .unknown

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Permissions.Title")
                    .font(.title2)
                    .bold()

                Text("Permissions.Description")
                    .font(.caption)
                    .foregroundStyle(.primary)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Permissions.Step1.Title")
                        .font(.headline)

                    permissionRow(
                        title: String(localized: "Permissions.Screen.Title"),
                        detail: String(localized: "Permissions.Screen.Detail"),
                        status: screenStatus,
                        requestAction: requestScreenIfPossible,
                        checkAction: refreshScreenStatus
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Permissions.Step2.Title")
                        .font(.headline)

                    permissionRow(
                        title: String(localized: "Permissions.Mic.Title"),
                        detail: String(localized: "Permissions.Mic.Detail"),
                        status: micStatus,
                        requestAction: requestMicrophone,
                        checkAction: refreshMicrophoneStatus
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Permissions.Step3.Title")
                        .font(.headline)

                    permissionRow(
                        title: String(localized: "Permissions.Camera.Title"),
                        detail: String(localized: "Permissions.Camera.Detail"),
                        status: cameraStatus,
                        requestAction: requestCamera,
                        checkAction: refreshCameraStatus
                    )
                }

                Divider()

                HStack {
                    Button("Permissions.RecheckAll", action: refreshAll)
                    #if os(macOS)
                    Button("Permissions.OpenSystemSettings") {
                        openPrivacyPreferences()
                    }
                    #endif
                    Spacer()
                }
                .padding(.top, 4)

                Text("Permissions.Tips")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: refreshAll)
        .accessibilityIdentifier("RecorderPermissionsView")
    }

    // MARK: - UI helpers

    private func permissionRow(
        title: String,
        detail: String,
        status: PermissionStatus,
        requestAction: @escaping () -> Void,
        checkAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusDot(color: status.color, label: "\(title)：\(status.label)")
                Spacer()
                Button("Permissions.CheckStatus", action: checkAction)
                    .buttonStyle(.bordered)
                Button("Permissions.RequestPermission", action: requestAction)
                    .buttonStyle(.borderedProminent)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func statusDot(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Refresh

    private func refreshAll() {
        refreshScreenStatus()
        refreshMicrophoneStatus()
        refreshCameraStatus()
    }

    private func refreshMicrophoneStatus() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micStatus = mapAVStatus(status)
    }

    private func refreshCameraStatus() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraStatus = mapAVStatus(status)
    }

    private func mapAVStatus(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    // MARK: - Requests

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.micStatus = granted ? .granted : .denied
            }
        }
    }

    private func requestCamera() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                self.cameraStatus = granted ? .granted : .denied
            }
        }
    }

    private func refreshScreenStatus() {
        #if os(macOS)
        if #available(macOS 10.15, *) {
            let ok = CGPreflightScreenCaptureAccess()
            screenStatus = ok ? .granted : .denied
        } else {
            screenStatus = .unknown
        }
        #else
        screenStatus = .unknown
        #endif
    }

    private func requestScreenIfPossible() {
        #if os(macOS)
        if #available(macOS 10.15, *) {
            // 如果已经授权，则仅刷新状态
            if CGPreflightScreenCaptureAccess() {
                screenStatus = .granted
                return
            }
            // 触发系统原生授权弹窗；调用本身是异步的。
            CGRequestScreenCaptureAccess()
            // 延迟一小段时间后重新检查状态（用户可能刚刚勾选了权限）
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.refreshScreenStatus()
            }
        }
        #endif
    }

    #if os(macOS)
    private func openPrivacyPreferences() {
        // 尝试打开「隐私与安全性」偏好设置；即使 URL 失败也不会影响主流程。
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
    #endif
}

#Preview("Permissions") {
    RecorderPermissionsView()
        .frame(width: 720, height: 520)
}
