import SwiftUI
import AVFoundation
import UIKit

/// 主界面：复刻安卓 activity_main.xml 的层级——4:5 取景框 / 网格 / 水平仪 / 对焦框 /
/// 焦段条 / 闪光灯 / 快门 / 左下角缩略图 / 右下角相机图案（进设置）。
struct CameraScreen: View {
    @AppStorage("app_lang") private var langRaw: String = "zh"

    @StateObject private var camera = CameraSession()
    @StateObject private var motion = MotionRoll()

    @State private var focalIndex = 0
    @State private var showSettings = false
    @State private var showGallery = false
    @State private var thumb: UIImage?
    @State private var focusLocal: CGPoint?
    @State private var focusLocked = false
    @State private var toast: String?

    private var t: L10n { L10n(raw: langRaw) }
    private let focalList: [(mm: Int, zoom: String, factor: CGFloat)] = [
        (23, "1x", 1.0),
        (75, "3x", 3.0),
        (120, "5x", 5.0)
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                previewArea
                ZStack {
                    if camera.busy {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(height: 28)
                .padding(.top, 8)

                focalBar

                Spacer(minLength: 6)

                bottomBar
            }
            .padding(.top, 4)

            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.72)))
                        .padding(.bottom, 20)
                }
            }
        }
        .statusBarHidden(false)
        .onAppear {
            camera.onSaved = { refreshThumb() }
            camera.prepare()
            motion.start()
            refreshThumb()
        }
        .onDisappear {
            camera.stop()
            motion.stop()
        }
        .sheet(isPresented: $showSettings, onDismiss: { refreshThumb() }) {
            SettingsView()
        }
        .sheet(isPresented: $showGallery, onDismiss: { refreshThumb() }) {
            GalleryView()
        }
    }

    // MARK: - 取景

    private var previewArea: some View {
        ZStack {
            CameraPreview(session: camera.session, onTap: handleTap)
            GridLinesView()
            LevelView(motion: motion)
            if let point = focusLocal {
                FocusBox(color: focusLocked ? Color(red: 0.35, green: 0.95, blue: 0.55) : .white)
                    .position(point)
            }
            if camera.permissionDenied {
                Text(t.s("permission_camera"))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding()
            }
        }
        .aspectRatio(4.0 / 5.0, contentMode: .fit)
        .padding(.horizontal, 20)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    private func handleTap(devicePoint: CGPoint, localPoint: CGPoint) {
        camera.focus(at: devicePoint)
        focusLocal = localPoint
        focusLocked = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            focusLocked = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            focusLocal = nil
            focusLocked = false
        }
    }

    // MARK: - 焦段条

    private var focalBar: some View {
        HStack(spacing: 0) {
            ForEach(0..<focalList.count, id: \.self) { index in
                Button {
                    selectFocal(index)
                } label: {
                    VStack(spacing: 1) {
                        Text("\(focalList[index].mm)")
                            .font(.system(size: 17, weight: .bold))
                        Text(focalList[index].zoom)
                            .font(.system(size: 11))
                    }
                    .foregroundColor(focalIndex == index
                                     ? Color(red: 1.0, green: 0.82, blue: 0.29)
                                     : Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
    }

    private func selectFocal(_ index: Int) {
        focalIndex = index
        camera.setZoom(focalList[index].factor)
    }

    // MARK: - 底部操作区

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Button {
                camera.toggleTorch()
            } label: {
                Image(systemName: camera.torchOn ? "bolt.fill" : "bolt.slash")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(camera.torchOn
                                     ? Color(red: 1.0, green: 0.82, blue: 0.29)
                                     : Color.white.opacity(0.85))
                    .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)

            HStack(alignment: .center, spacing: 0) {
                thumbButton
                Spacer(minLength: 0)
                shutterButton
                Spacer(minLength: 0)
                logoButton
            }
            .padding(.horizontal, 42)
        }
        .padding(.bottom, 16)
    }

    private var thumbButton: some View {
        Button {
            showGallery = true
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12))
                if let thumb {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 58, height: 58)
                        .clipped()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    private var shutterButton: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.9), lineWidth: 3)
                .frame(width: 78, height: 78)
            Circle()
                .fill(Color.white)
                .frame(width: 62, height: 62)
        }
        .contentShape(Circle())
        .opacity(camera.busy ? 0.55 : 1.0)
        .onTapGesture {
            shoot()
        }
    }

    private var logoButton: some View {
        Button {
            showSettings = true
        } label: {
            Image("mamiya")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 58, height: 58)
        }
        .buttonStyle(.plain)
    }

    private func shoot() {
        guard !camera.busy else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        camera.capture()
    }

    // MARK: - 缩略图

    private func refreshThumb() {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = PhotoStore.shared.latestImage(maxPixel: 240)
            DispatchQueue.main.async {
                thumb = image
            }
        }
    }
}
