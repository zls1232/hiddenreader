import Foundation
import SwiftUI
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

    init() {
        try? FileManager.default.createDirectory(at: Self.vaultDirectory, withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - 索引持久化
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

    // MARK: - 导入（用 PHPickerResult 拿可靠的 assetIdentifier）
    @MainActor
    func importResults(_ results: [PHPickerResult]) async {
        isImporting = true
        defer { isImporting = false }

        var identifiers: [String] = []

        for result in results {
            let provider = result.itemProvider
            do {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    let data = try await provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier)
                    addFile(data: data, ext: dataExtension(data), kind: .photo)
                    if deleteOriginals, let id = result.assetIdentifier, !id.isEmpty {
                        identifiers.append(id)
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                            || provider.hasItemConformingToTypeIdentifier(UTType.video.identifier) {
                    if let url = try await loadVideoFile(provider) {
                        moveFile(from: url, kind: .video)
                        if deleteOriginals, let id = result.assetIdentifier, !id.isEmpty {
                            identifiers.append(id)
                        }
                    }
                }
            } catch {
                lastError = error.localizedDescription
            }
        }
        saveIndex()

        if !identifiers.isEmpty {
            await deleteOriginals(with: identifiers)
        }
    }

    private func loadVideoFile(_ provider: NSItemProvider) async throws -> URL? {
        let type = UTType.movie.identifier
        let url = try await provider.loadFileRepresentation(forTypeIdentifier: type)
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }

    private func dataExtension(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if brand.hasPrefix("heic") || brand.hasPrefix("heix") || brand.hasPrefix("mif1") || brand.hasPrefix("msf1") {
                return "heic"
            }
        }
        return "jpg"
    }

    private func addFile(data: Data, ext: String, kind: VaultItem.Kind) {
        let name = UUID().uuidString + "." + ext
        let dest = Self.vaultDirectory.appendingPathComponent(name)
        do {
            try data.write(to: dest, options: .atomic)
            items.insert(VaultItem(id: UUID(), fileName: name, kind: kind, dateAdded: Date()), at: 0)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func moveFile(from url: URL, kind: VaultItem.Kind) {
        let name = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        let dest = Self.vaultDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            items.insert(VaultItem(id: UUID(), fileName: name, kind: kind, dateAdded: Date()), at: 0)
        } catch {
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                items.insert(VaultItem(id: UUID(), fileName: name, kind: kind, dateAdded: Date()), at: 0)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    // MARK: - 删除系统相册原图
    private func deleteOriginals(with identifiers: [String]) async {
        let granted = await ensureLibraryAccess()
        guard granted else {
            lastError = "未获得完整相册访问权限，原图未删除。请在 设置-隐私与安全性-照片 中把『闲阅』权限改为『所有照片』后重试"
            return
        }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else {
            lastError = "原图已找不到（可能已被删除），可忽略"
            return
        }

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

    // MARK: - 恢复到系统相册
    func restore(_ item: VaultItem) {
        Task {
            guard await ensureLibraryAccess() else {
                await MainActor.run { self.lastError = "未获得相册访问权限" }
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
        case .authorized:
            return true
        case .limited:
            // 受限访问无法删除原图
            return false
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
        default:
            return false
        }
    }
}
