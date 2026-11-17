import SwiftUI
import UIKit

/// 内置相册：读 App 沙盒 Documents/goosecam，支持多选删除、全屏缩放与左右切换。
struct GalleryView: View {
    @AppStorage("app_lang") private var langRaw: String = "zh"
    @Environment(\.dismiss) private var dismiss

    @State private var items: [PhotoItem] = []
    @State private var multiSelect = false
    @State private var selected: Set<String> = []
    @State private var viewerItem: PhotoItem?
    @State private var showBatchConfirm = false

    private var t: L10n { L10n(raw: langRaw) }
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if items.isEmpty {
                    Text(t.s("gallery_empty"))
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.55))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(items) { item in
                                cell(item)
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text(t.s("gallery_title")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: { Text(t.s("back")) }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        toggleMulti()
                    } label: {
                        Text(multiSelect ? t.s("select_done") : t.s("multi_select"))
                    }
                    .disabled(items.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if multiSelect && !selected.isEmpty {
                    Button {
                        showBatchConfirm = true
                    } label: {
                        Text(t.deleteSelected(selected.count))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                }
            }
            .confirmationDialog(Text(t.s("gallery_delete_confirm")), isPresented: $showBatchConfirm, titleVisibility: .visible) {
                Button(role: .destructive) { deleteSelected() } label: { Text(t.s("confirm_delete")) }
                Button(role: .cancel) {} label: { Text(t.s("cancel")) }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { reload() }
        .fullScreenCover(item: $viewerItem, onDismiss: { reload() }) { item in
            PhotoViewer(items: items, initial: item, langRaw: langRaw) { target in
                PhotoStore.shared.delete([target.url])
                viewerItem = nil
                reload()
            }
        }
    }

    // MARK: - 网格

    private func cell(_ item: PhotoItem) -> some View {
        Button {
            if multiSelect {
                if selected.contains(item.id) {
                    selected.remove(item.id)
                } else {
                    selected.insert(item.id)
                }
            } else {
                viewerItem = item
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                PhotoThumb(url: item.url)

                VStack {
                    Spacer()
                    HStack {
                        Text(Self.dateFormatter.string(from: item.date))
                            .font(.system(size: 10))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.55))
                        Spacer(minLength: 0)
                    }
                }

                if multiSelect {
                    ZStack {
                        Circle()
                            .fill(selected.contains(item.id)
                                  ? Color(red: 1.0, green: 0.82, blue: 0.29)
                                  : Color.black.opacity(0.45))
                            .frame(width: 22, height: 22)
                        if selected.contains(item.id) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.black)
                        } else {
                            Circle()
                                .stroke(Color.white.opacity(0.7), lineWidth: 1)
                                .frame(width: 22, height: 22)
                        }
                    }
                    .padding(6)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .overlay(
                Rectangle()
                    .stroke(selected.contains(item.id) && multiSelect
                            ? Color(red: 1.0, green: 0.82, blue: 0.29)
                            : Color.clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reload() {
        items = PhotoStore.shared.list()
        if !multiSelect { selected.removeAll() }
    }

    private func toggleMulti() {
        multiSelect.toggle()
        if !multiSelect { selected.removeAll() }
    }

    private func deleteSelected() {
        let targets = items.filter { selected.contains($0.id) }.map { $0.url }
        PhotoStore.shared.delete(targets)
        selected.removeAll()
        multiSelect = false
        reload()
    }
}

/// 单张缩略图，异步抽样解码。
struct PhotoThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white.opacity(0.06)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    ProgressView().tint(.white.opacity(0.4))
                }
            }
        }
        .task(id: url.path) {
            let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                ThumbCache.shared.image(for: url, maxPixel: 360)
            }.value
            if let loaded { image = loaded }
        }
    }
}

/// 全屏查看：双指缩放（1–4 倍）、放大后拖动、未放大时左右滑动切换。
struct PhotoViewer: View {
    let items: [PhotoItem]
    let langRaw: String
    let onDelete: (PhotoItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int = 0
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var showDeleteConfirm = false

    private var t: L10n { L10n(raw: langRaw) }
    private var current: PhotoItem { items[min(max(index, 0), max(items.count - 1, 0))] }

    init(items: [PhotoItem], initial: PhotoItem, langRaw: String, onDelete: @escaping (PhotoItem) -> Void) {
        self.items = items
        self.langRaw = langRaw
        self.onDelete = onDelete
        if let position = items.firstIndex(where: { $0.id == initial.id }) {
            _index = State(initialValue: position)
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnification)
                    .simultaneousGesture(panOrSwipe)
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Text(t.s("back"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                Spacer()
            }
        }
        .statusBarHidden(true)
        .task(id: current.id) { await load() }
        .confirmationDialog(Text(t.s("gallery_delete_confirm")), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(role: .destructive) { onDelete(current) } label: { Text(t.s("confirm_delete")) }
            Button(role: .cancel) {} label: { Text(t.s("cancel")) }
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(1, baseScale * value), 4)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1.01 {
                    scale = 1
                    baseScale = 1
                    offset = .zero
                }
            }
    }

    private var panOrSwipe: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    offset = value.translation
                }
            }
            .onEnded { value in
                if scale > 1 {
                    if abs(value.translation.height) > 220 || abs(value.translation.width) > 320 {
                        offset = .zero
                    }
                    return
                }
                if value.translation.width < -60 {
                    step(1)
                } else if value.translation.width > 60 {
                    step(-1)
                }
            }
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard next >= 0 && next < items.count else { return }
        index = next
        image = nil
        scale = 1
        baseScale = 1
        offset = .zero
    }

    private func load() async {
        let url = current.url
        let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            PhotoStore.shared.thumbnail(for: url, maxPixel: 2600)
        }.value
        if let loaded { image = loaded }
    }
}
