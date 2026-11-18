import SwiftUI
import PhotosUI
import UIKit

/// 设置页：选择相机 / 导入照片 / 选择语言 / 软件说明，与安卓 SettingsActivity 对齐。
struct SettingsView: View {
    @AppStorage("app_lang") private var langRaw: String = "zh"
    @Environment(\.dismiss) private var dismiss

    @StateObject private var importer = ImportProcessor()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showGallery = false

    private var t: L10n { L10n(raw: langRaw) }
    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.52"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    cameraSection
                    importSection
                    languageSection
                    aboutSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(Text(t.s("settings_title")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: { Text(t.s("select_done")) }
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    importer.tick(l10n: L10n(raw: langRaw))
                }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showGallery) {
            GalleryView()
        }
    }

    // MARK: - 选择相机

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(t.s("choose_camera"))

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image("mamiya")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 46, height: 46)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.s("goose72"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.29))
                        Text(t.s("goose72_desc"))
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.62))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.29))
                }

                Divider().background(Color.white.opacity(0.12))

                HStack(spacing: 12) {
                    Image(systemName: "camera")
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.3))
                        .frame(width: 46, height: 46)
                    Text(t.s("upcoming"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.3))
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .background(cardBackground)
        }
    }

    // MARK: - 导入照片

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(t.s("import_photo"))

            VStack(alignment: .leading, spacing: 10) {
                Text(t.s("import_desc"))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: 24,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Text(t.s("import_button"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(
                                Capsule().fill(importer.processing
                                               ? Color.white.opacity(0.45)
                                               : Color(red: 1.0, green: 0.82, blue: 0.29))
                            )
                    }
                    .disabled(importer.processing)

                    Text(importer.statusText.isEmpty ? t.s("import_estimate") : importer.statusText)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }

                Button {
                    showGallery = true
                } label: {
                    Text(t.s("open_gallery"))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(cardBackground)
        }
        .onChange(of: pickerItems) { newItems in
            guard !newItems.isEmpty else { return }
            importer.run(newItems, l10n: t)
        }
    }

    // MARK: - 语言

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(t.s("language"))

            HStack(spacing: 24) {
                Button {
                    langRaw = "zh"
                } label: {
                    Text(t.s("chinese"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(langRaw == "zh"
                                         ? Color(red: 1.0, green: 0.82, blue: 0.29)
                                         : Color.white)
                }
                .buttonStyle(.plain)

                Button {
                    langRaw = "en"
                } label: {
                    Text(t.s("english"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(langRaw == "en"
                                         ? Color(red: 1.0, green: 0.82, blue: 0.29)
                                         : Color.white)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
            }
            .padding(14)
            .background(cardBackground)
        }
    }

    // MARK: - 软件说明

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(t.s("about"))

            VStack(alignment: .leading, spacing: 10) {
                infoRow(t.s("version"), version)
                infoRow(t.s("updated"), t.s("updated_date"))
                infoRow(t.s("developer"), t.s("developer_name"))
                HStack(spacing: 10) {
                    Text(t.s("contact"))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                    Spacer(minLength: 10)
                    Button {
                        if let url = URL(string: "mailto:\(t.s("contact_email"))") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text(t.s("contact_email"))
                            .font(.system(size: 12))
                            .foregroundColor(Color(red: 1.0, green: 0.82, blue: 0.29))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(cardBackground)
        }
    }

    // MARK: - 小组件

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.55))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.55))
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
        }
    }
}

/// 导入批处理：多选照片逐张按 M72 流水线运算并落盘，同时换算剩余时间。
@MainActor
final class ImportProcessor: ObservableObject {
    @Published var processing = false
    @Published var total = 0
    @Published var done = 0
    @Published var failed = 0
    @Published var statusText = ""

    private var startedAt = Date()

    func run(_ picks: [PhotosPickerItem], l10n: L10n) {
        guard !processing else { return }
        processing = true
        total = picks.count
        done = 0
        failed = 0
        startedAt = Date()
        statusText = l10n.remaining(ImportProcessor.format(Double(picks.count) * 3.0))

        Task {
            var failCount = 0
            for item in picks {
                let ok = await ImportProcessor.process(item)
                done += 1
                if !ok { failCount += 1 }
                failed = failCount
                tick(l10n: l10n)
            }
            processing = false
            statusText = l10n.s("import_done")
        }
    }

    func tick(l10n: L10n) {
        guard processing, total > 0, done < total else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let perPhoto = done > 0 ? elapsed / Double(done) : 3.0
        statusText = l10n.remaining(ImportProcessor.format(perPhoto * Double(total - done)))
    }

    nonisolated static func process(_ item: PhotosPickerItem) async -> Bool {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let raw = UIImage(data: data) else { return false }
        return await Task.detached(priority: .userInitiated) { () -> Bool in
            guard let out = M72Filter.processImport(raw) else { return false }
            PhotoStore.shared.save(out, prefix: "IMP")
            return true
        }.value
    }

    nonisolated static func format(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
