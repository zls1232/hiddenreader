import SwiftUI
import PhotosUI
import AVKit
import AVFoundation
import UIKit

struct VaultView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = VaultStore()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var viewingPhoto: VaultItem?
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
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: 0,
                        matching: .any(of: [.images, .videos])
                    ) {
                        Image(systemName: "plus")
                    }
                }
            }
            .onChange(of: pickerItems) { items in
                guard !items.isEmpty else { return }
                Task {
                    await store.importItems(items)
                    pickerItems = []
                }
            }
            .sheet(item: $viewingPhoto) { item in
                PhotoDetailView(item: item, store: store)
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
            .alert(isPresented: $showAlert) {
                Alert(title: Text("提示"),
                      message: Text(store.lastError ?? ""),
                      dismissButton: .default(Text("好")))
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(store.items) { item in
                    ThumbnailView(item: item)
                        .aspectRatio(1, contentMode: .fill)
                        .clipped()
                        .onTapGesture {
                            if item.kind == .photo { viewingPhoto = item } else { viewingVideo = item }
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
            .padding(6)
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
                        .font(.title)
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

// MARK: - 照片详情
struct PhotoDetailView: View {
    let item: VaultItem
    @ObservedObject var store: VaultStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let ui = UIImage(contentsOfFile: item.fileURL.path) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: ui).resizable().scaledToFit()
                    }
                } else {
                    Text("无法显示")
                }
            }
            .navigationTitle("照片")
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
