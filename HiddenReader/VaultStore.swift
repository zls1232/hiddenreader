import Foundation
import PhotosUI
import Photos
import UniformTypeIdentifiers

struct VaultItem: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let kind: Kind
    let dateAdded: Date

    enum Kind: String, Codable {
        case photo
        case video
    }

    var fileURL: URL {
        VaultStore.vaultDirectory.appendingPathComponent(fileName)
    }
}

final class VaultStore: ObservableObject {
    static let vaultDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("HiddenVault", isDirectory: true)
    }()

    private static let indexFile = vaultDirectory.appendingPathComponent("index.json")

    @Published var items: [VaultItem] = []
    @Published var isImporting = false
    @Published var deleteOriginals = true
    @Published var lastError: String?

    private var pendingIdentifiers: [String] = []

    init() {
        try? FileManager.default.createDirectory(at: Self.vaultDirectory, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - 持久化索引
    private func loadIndex() {
        guard let data = try? Data(contentsOf: Self.indexFile),
              let decoded = try? JSONDecoder().decode([VaultItem].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: Self.indexFile, options: .atomic)
        }
    }

    // MARK: - 导入
    @MainActor
    func importItems(_ pickerItems: [PhotosPickerItem]) async {
        isImporting = true
        defer { isImporting = false }

        for item in pickerItems {
            do {
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .image) }) {
                    if let data = try await item.loadTransferable(type: Data.self) {
                        addFile(data: data, ext: "jpg", kind: .photo, identifier: item.itemIdentifier)
                    }
                } else if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) }) {
                    if let movie = try await item.loadTransferable(type: MovieFile.self) {
                        moveFile(from: movie.url, kind: .video, identifier: item.itemIdentifier)
                    }
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        saveIndex()

        if !pendingIdentifiers.isEmpty {
            await deleteQueuedOriginals()
        }
    }

    private func addFile(data: Data, ext: String, kind: VaultItem.Kind, identifier: String?) {
        let name = UUID().uuidString + "." + ext
        let dest = Self.vaultDirectory.appendingPathComponent(name)
        do {
            try data.write(to: dest, options: .atomic)
            items.insert(VaultItem(id: UUID(), fileName: name, kind: kind, dateAdded: Date()), at: 0)
            queueDeletion(identifier)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func moveFile(from url: URL, kind: VaultItem.Kind, identifier: String?) {
        let name = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        let dest = Self.vaultDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            items.insert(VaultItem(id: UUID(), fileName: name, kind: kind, dateAdded: Date()), at: 0)
            queueDeletion(identifier)
        } catch {
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                items.insert(VaultItem(id: UUID(), fileName: name, kind: kind, dateAdded: Date()), at: 0)
                queueDeletion(identifier)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func queueDeletion(_ identifier: String?) {
        if deleteOriginals, let identifier, !identifier.isEmpty {
            pendingIdentifiers.append(identifier)
        }
    }

    private func deleteQueuedOriginals() async {
        guard !pendingIdentifiers.isEmpty else { return }
        let ids = pendingIdentifiers
        pendingIdentifiers.removeAll()

        let granted = await ensureLibraryAccess()
        guard granted else {
            lastError = "未授权访问相册，原图未删除，请在系统相册手动删除"
            return
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        guard assets.count > 0 else { return }

        await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            } completionHandler: { success, error in
                if !success {
                    DispatchQueue.main.async { self.lastError = error?.localizedDescription }
                }
                continuation.resume()
            }
        }
    }

    // MARK: - 恢复到相册
    func restore(_ item: VaultItem) {
        Task {
            guard await ensureLibraryAccess() else {
                await MainActor.run { self.lastError = "未授权访问相册" }
                return
            }
            let url = item.fileURL
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                if item.kind == .photo {
                    request.addResource(with: .photo, fileURL: url, options: options)
                } else {
                    request.addResource(with: .video, fileURL: url, options: options)
                }
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.items.removeAll { $0.id == item.id }
                        self.saveIndex()
                    } else {
                        self.lastError = error?.localizedDescription ?? "恢复失败"
                    }
                }
            }
        }
    }

    // MARK: - 删除
    func delete(_ item: VaultItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
        items.removeAll { $0.id == item.id }
        saveIndex()
    }

    // MARK: - 权限
    func ensureLibraryAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
        default:
            return false
        }
    }
}
