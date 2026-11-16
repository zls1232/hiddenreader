import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
import UIKit

enum MoveContext: Identifiable {
    case single(VaultItem)
    case batch(Set<UUID>)

    var id: String {
        switch self {
        case .single(let item): return item.id.uuidString
        case .batch: return "batch"
        }
    }
}

// MARK: - 主界面（资料库）
struct VaultView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = VaultStore()
    @State private var showPicker = false
    @State private var galleryPhotos: [VaultItem] = []
    @State private var galleryIndex = 0
    @State private var showGallery = false
    @State private var viewingVideo: VaultItem?
    @State private var deleting: VaultItem?
    @State private var showAlert = false
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var confirmBatchDelete = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var moveContext: MoveContext?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                folderTabs

                if store.filteredItems.isEmpty {
                    emptyView
                } else {
                    grid
                }

                if isSelecting {
                    selectionBar
                } else {
                    Toggle("导入后删除相册原图", isOn: $store.deleteOriginals)
                        .font(.footnote)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
            }
            .overlay {
                if store.isImporting {
                    importingOverlay
                }
            }
            .navigationTitle(isSelecting ? "已选 \(selectedIDs.count) 项" : "资料库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isSelecting {
                        Button("取消") {
                            isSelecting = false
                            selectedIDs.removeAll()
                        }
                    } else {
                        Button("返回") { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isSelecting {
                        Button(selectedIDs.count == store.filteredItems.count ? "取消全选" : "全选") {
                            if selectedIDs.count == store.filteredItems.count {
                                selectedIDs.removeAll()
                            } else {
                                selectedIDs = Set(store.filteredItems.map { $0.id })
                            }
                        }
                    } else {
                        HStack(spacing: 16) {
                            Button("选择") { isSelecting = true }
                            Button {
                                showPicker = true
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                PHPickerView { results in
                    let target: String
                    if case .folder(let name) = store.currentSection {
                        target = name
                    } else {
                        target = VaultStore.defaultFolder
                    }
                    Task { await store.importResults(results, into: target) }
                }
            }
            .sheet(item: $moveContext) { context in
                FolderPickerView(folders: [VaultStore.defaultFolder] + store.customFolders, title: "移动到") { folder in
                    switch context {
                    case .single(let item):
                        store.move(item, to: folder)
                    case .batch(let ids):
                        store.moveItems(ids, to: folder)
                    }
                    selectedIDs.removeAll()
                    isSelecting = false
                }
            }
            .fullScreenCover(isPresented: $showGallery) {
                PhotoGalleryView(items: galleryPhotos, startIndex: galleryIndex)
            }
            .sheet(item: $viewingVideo) { item in
                VideoDetailView(item: item, store: store)
            }
            .confirmationDialog("确认删除", isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let item = deleting { store.delete(item) }
                    deleting = nil
                }
                Button("取消", role: .cancel) { deleting = nil }
            } message: {
                Text("将从本机彻底删除，且不可恢复。")
            }
            .confirmationDialog("确认删除所选 \(selectedIDs.count) 项", isPresented: $confirmBatchDelete) {
                Button("删除 \(selectedIDs.count) 项", role: .destructive) {
                    store.deleteItems(selectedIDs)
                    selectedIDs.removeAll()
                    isSelecting = false
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将从本机彻底删除，且不可恢复。")
            }
            .alert("新建文件夹", isPresented: $showNewFolderAlert) {
                TextField("文件夹名称", text: $newFolderName)
                Button("创建") {
                    let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if store.createFolder(trimmed) {
                        store.currentSection = .folder(trimmed)
                    }
                    newFolderName = ""
                }
                Button("取消", role: .cancel) { newFolderName = "" }
            } message: {
                Text("给新文件夹起个名字")
            }
            .alert("提示", isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "")
            }
            .alert("导入完成", isPresented: Binding(
                get: { store.importDoneCount != nil },
                set: { if !$0 { store.importDoneCount = nil } }
            )) {
                Button("好", role: .cancel) { store.importDoneCount = nil }
            } message: {
                Text("已导入 \(store.importDoneCount ?? 0) 项")
            }
            .onChange(of: store.lastError) { _ in
                if store.lastError != nil { showAlert = true }
            }
        }
    }

    private var importingOverlay: some View {
        VStack(spacing: 10) {
            ProgressView()
            if let p = store.importProgress {
                Text("正在导入 \(p.done) / \(p.total)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .padding(24)
        .background(Color(.systemBackground).opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 10)
    }

    // MARK: - 顶部文件夹标签栏
    private var folderTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                tabChip("收藏夹", section: .favorites, icon: "star.fill")
                tabChip(VaultStore.defaultFolder, section: .folder(VaultStore.defaultFolder), icon: "folder.fill")
                ForEach(store.customFolders, id: \.self) { folder in
                    tabChip(folder, section: .folder(folder), icon: "folder")
                }
                Button {
                    showNewFolderAlert = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("新建")
                    }
                    .font(.footnote)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(.systemGray5))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
    }

    private func tabChip(_ label: String, section: VaultSection, icon: String) -> some View {
        let selected = store.currentSection == section
        return Button {
            store.currentSection = section
            if isSelecting {
                selectedIDs.removeAll()
                isSelecting = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.footnote)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor : Color(.systemGray5))
            .foregroundColor(selected ? .white : .primary)
            .clipShape(Capsule())
        }
    }

    // MARK: - 空状态
    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text(emptyTitle)
                .foregroundColor(.secondary)
            Text("点右上角 + 导入照片或视频")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch store.currentSection {
        case .favorites:
            return "收藏夹还是空的"
        case .folder(let name):
            return "「\(name)」还没有内容"
        }
    }

    // MARK: - 网格
    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                ForEach(store.filteredItems) { item in
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(ThumbnailView(item: item))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(alignment: .topTrailing) {
                            if isSelecting {
                                Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundColor(selectedIDs.contains(item.id) ? .blue : .white)
                                    .shadow(radius: 1)
                                    .padding(5)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelecting {
                                toggleSelection(item)
                            } else if item.kind == .photo {
                                openGallery(at: item)
                            } else {
                                viewingVideo = item
                            }
                        }
                        .contextMenu {
                            Button {
                                store.toggleFavorite(item)
                            } label: {
                                Label(item.isFavorite ? "取消收藏" : "收藏", systemImage: item.isFavorite ? "star.slash" : "star")
                            }
                            Button {
                                moveContext = .single(item)
                            } label: {
                                Label("移动到文件夹", systemImage: "folder")
                            }
                            Button {
                                store.restore(item)
                            } label: {
                                Label("恢复到相册", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                deleting = item
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(2)
        }
    }

    // MARK: - 多选操作栏
    private var selectionBar: some View {
        HStack {
            Button {
                moveContext = .batch(selectedIDs)
            } label: {
                VStack(spacing: 2) { Image(systemName: "folder"); Text("移动") }
            }
            .disabled(selectedIDs.isEmpty)

            Spacer()

            Button {
                store.setFavorite(selectedIDs, true)
                selectedIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 2) { Image(systemName: "star"); Text("收藏") }
            }
            .disabled(selectedIDs.isEmpty)

            Spacer()

            Button {
                store.restoreItems(selectedIDs)
                selectedIDs.removeAll()
                isSelecting = false
            } label: {
                VStack(spacing: 2) { Image(systemName: "square.and.arrow.up"); Text("恢复") }
            }
            .disabled(selectedIDs.isEmpty)

            Spacer()

            Button(role: .destructive) {
                confirmBatchDelete = true
            } label: {
                VStack(spacing: 2) { Image(systemName: "trash"); Text("删除") }
            }
            .disabled(selectedIDs.isEmpty)
        }
        .font(.footnote)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func toggleSelection(_ item: VaultItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    private func openGallery(at item: VaultItem) {
        galleryPhotos = store.filteredItems.filter { $0.kind == .photo }
        galleryIndex = galleryPhotos.firstIndex(where: { $0.id == item.id }) ?? 0
        showGallery = true
    }
}

// MARK: - 文件夹选择
struct FolderPickerView: View {
    let folders: [String]
    let title: String
    var onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(folders, id: \.self) { folder in
                    Button {
                        onSelect(folder)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.yellow)
                            Text(folder)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

// MARK: - PHPicker 封装
struct PHPickerView: UIViewControllerRepresentable {
    var onPick: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 0
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: ([PHPickerResult]) -> Void
        init(onPick: @escaping ([PHPickerResult]) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onPick(results)
        }
    }
}

// MARK: - 缩略图
struct ThumbnailView: View {
    let item: VaultItem

    var body: some View {
        if item.kind == .photo {
            if let ui = UIImage(contentsOfFile: item.fileURL.path) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                placeholder
            }
        } else {
            if let thumb = videoThumbnail(item.fileURL) {
                ZStack {
                    Image(uiImage: thumb).resizable().scaledToFill()
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .shadow(radius: 2)
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.gray.opacity(0.3)
            Image(systemName: item.kind == .photo ? "photo" : "video")
                .foregroundColor(.secondary)
        }
    }

    private func videoThumbnail(_ url: URL) -> UIImage? {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 全屏照片查看器
struct PhotoGalleryView: View {
    let items: [VaultItem]
    let startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(items: [VaultItem], startIndex: Int) {
        self.items = items
        self.startIndex = startIndex
        self._selection = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selection) {
                ForEach(0..<items.count, id: \.self) { index in
                    ZoomableImageView(image: UIImage(contentsOfFile: items[index].fileURL.path) ?? UIImage())
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                }
                Spacer()
                Text("\(selection + 1) / \(items.count)")
                    .font(.subheadline)
                    .foregroundColor(.white)
                Spacer()
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .statusBarHidden(true)
    }
}

// MARK: - 可缩放图片视图
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 6.0
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .black
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        scrollView.zoomScale = 1.0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let location = gesture.location(in: imageView)
                let size = CGSize(width: 120, height: 120)
                let rect = CGRect(origin: CGPoint(x: location.x - size.width / 2, y: location.y - size.height / 2), size: size)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

// MARK: - 视频详情
struct VideoDetailView: View {
    let item: VaultItem
    @ObservedObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            store.restore(item)
                            dismiss()
                        } label: {
                            Label("恢复到相册", systemImage: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            store.delete(item)
                            dismiss()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                player = AVPlayer(url: item.fileURL)
                player?.play()
            }
            .onDisappear {
                player?.pause()
            }
        }
    }
}
