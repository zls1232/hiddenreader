import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
import UIKit

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.items.isEmpty {
                    emptyView
                } else {
                    grid
                }

                Toggle("导入后删除相册原图", isOn: $store.deleteOriginals)
                    .font(.footnote)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }
            .navigationTitle("资料库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showPicker = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showPicker) {
                PHPickerView { results in
                    Task { await store.importResults(results) }
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
            .alert("提示", isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "")
            }
            .onChange(of: store.lastError) { _ in
                if store.lastError != nil { showAlert = true }
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("暂无内容")
                .foregroundColor(.secondary)
            Text("点右上角 + 导入照片或视频")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                ForEach(store.items) { item in
                    ThumbnailView(item: item)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                        .onTapGesture {
                            if item.kind == .photo {
                                openGallery(at: item)
                            } else {
                                viewingVideo = item
                            }
                        }
                        .contextMenu {
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
            .padding(3)
        }
    }

    private func openGallery(at item: VaultItem) {
        galleryPhotos = store.items.filter { $0.kind == .photo }
        galleryIndex = galleryPhotos.firstIndex(where: { $0.id == item.id }) ?? 0
        showGallery = true
    }
}

// MARK: - PHPicker 封装（拿可靠的 assetIdentifier）
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

// MARK: - 全屏照片查看器（左右滑动 + 双指缩放）
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
        context.coordinator.imageView.image = image
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
