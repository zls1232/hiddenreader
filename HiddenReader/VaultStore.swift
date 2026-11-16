import Foundation
import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers

// 资料库分区：收藏夹 或 某个文件夹
enum VaultSection: Hashable {
    case favorites
    case folder(String)
}

struct VaultItem: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let kind: Kind
    let dateAdded: Date
    var folder: String
    var isFavorite: Bool

    enum Kind: String, Codable {
        case photo
        case video
    }

    var fileURL: URL {
        VaultStore.vaultDirectory.appendingPathComponent(fileName)
    }

    enum CodingKeys: String, CodingKey {
        case id, fileName, kind, dateAdded, folder, isFavorite
    }

    init(id: UUID = UUID(), fileName: String, kind: Kind, dateAdded: Date = Date(),
         folder: String = VaultStore.defaultFolder, isFavorite: Bool = false) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.dateAdded = dateAdded
        self.folder = folder
        self.isFavorite = isFavorite
    }

    // 兼容旧数据（没有 folder / isFavorite 字段）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        kind = try c.decode(Kind.self, forKey: .kind)
        dateAdded = try c.decode(Date.self, forKey: .dateAdded)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? VaultStore.defaultFolder
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}

final class VaultStore: ObservableObject {
    static let defaultFolder = "默认"

    static let vaultDirectory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("HiddenVault", isDirectory: true)
    }()

    private static let indexFile = vaultDirectory.appendingPathComponent("index.json")
    private static let foldersFile = vaultDirectory.appendingPathComponent("folders.json")

    @Published var items: [VaultItem] = []
    @Published var customFolders: [String] = []
    @Published var currentSection: VaultSection = .folder(defaultFolder)
    @Published var isImporting = false
    @Published var importProgress: (done: Int, total: Int)? = nil
    @Published var importDoneCount: Int? = nil
    @Published var deleteOriginals = true
    @Published var lastError: String?

    init() {
        try? FileManager.default.createDirectory(at: Self.vaultDirectory, withIntermediateDirectories: true)
        loadIndex()
        loadFolders()
    }

    var filteredItems: [VaultItem] {
        switch currentSection {
        case .favorites:
            return items.filter { $0.isFavorite }
        case .folder(let name):
            return items.filter { $0.folder == name }
        }
    }

    // MARK: - 持久化
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

    private func loadFolders() {
        if let data = try? Data(contentsOf: Self.foldersFile),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            customFolders = arr
        } else {
            customFolders = []
        }
    }

    private func saveFolders() {
        if let data = try? JSONEncoder().encode(customFolders) {
            try? data.write(to: Self.foldersFile, options: .atomic)
        }
    }

    // MARK: - 导入
    @MainActor
    func importResults(_ results: [PHPickerResult], into folder: String) async {
        isImporting = true
        importProgress = (0, results.count)
        defer {
            isImporting = false
            importProgress = nil
        }

        var identifiers: [String] = []
        var newItems: [VaultItem] = []
        var done = 0

        for result in results {
            let provider = result.itemProvider
            do {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let name = try await importFile(provider, typeIdentifier: UTType.image.identifier, kind: .photo) {
                        newItems.append(VaultItem(id: UUID(), fileName: name, kind: .photo, dateAdded: Date(), folder: folder))
                        if deleteOriginals, let id = result.assetIdentifier, !id.isEmpty { identifiers.append(id) }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                            || provider.hasItemConformingToTypeIdentifier(UTType.video.identifier) {
                    if let name = try await importFile(provider, typeIdentifier: UTType.movie.identifier, kind: .video) {
                        newItems.append(VaultItem(id: UUID(), fileName: name, kind: .video, dateAdded: Date(), folder: folder))
                        if deleteOriginals, let id = result.assetIdentifier, !id.isEmpty { identifiers.append(id) }
                    }
                }
            } catch {
                lastError = error.localizedDescription
            }
            done += 1
            importProgress = (done, results.count)
        }

        if !newItems.isEmpty {
            items.insert(contentsOf: newItems, at: 0)
            saveIndex()
            importDoneCount = newItems.count
        }

        if !identifiers.isEmpty {
            await deleteOriginals(with: identifiers)
        }
    }

    // 用 loadFileRepresentation 直接搬文件（比 loadData 快、省内存）
    private func importFile(_ provider: NSItemProvider, typeIdentifier: String, kind: VaultItem.Kind) async throws -> String? {
        let tempURL = try await loadFile(provider, typeIdentifier: typeIdentifier)
        let ext = finalExtension(for: tempURL, kind: kind)
        let name = UUID().uuidString + "." + ext
        let dest = Self.vaultDirectory.appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: tempURL, to: dest)
        } catch {
            try FileManager.default.copyItem(at: tempURL, to: dest)
        }
        return name
    }

    private func loadFile(_ provider: NSItemProvider, typeIdentifier: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
                    let copy = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString + "." + ext)
                    do {
                        try FileManager.default.copyItem(at: url, to: copy)
                        continuation.resume(returning: copy)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: NSError(domain: "import", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取文件"]))
                }
            }
        }
    }

    private func finalExtension(for url: URL, kind: VaultItem.Kind) -> String {
        if kind == .video {
            return url.pathExtension.isEmpty ? "mov" : url.pathExtension
        }
        return detectImageExtension(at: url)
    }

    private func detectImageExtension(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "jpg" }
        defer { try? handle.close() }
        let b = [UInt8](handle.readData(ofLength: 12))
        if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 {
            let brand = String(bytes: b[8..<12], encoding: .ascii) ?? ""
            if brand.hasPrefix("heic") || brand.hasPrefix("heix") || brand.hasPrefix("mif1") || brand.hasPrefix("msf1") { return "heic" }
        }
        return "jpg"
    }

    // MARK: - 文件夹
    func createFolder(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed != Self.defaultFolder, trimmed != "收藏夹" else { return false }
        guard !customFolders.contains(trimmed) else { return false }
        customFolders.append(trimmed)
        saveFolders()
        return true
    }

    // MARK: - 移动 / 收藏
    func move(_ item: VaultItem, to folder: String) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].folder = folder
            saveIndex()
        }
    }

    func moveItems(_ ids: Set<UUID>, to folder: String) {
        for id in ids {
            if let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx].folder = folder
            }
        }
        saveIndex()
    }

    func toggleFavorite(_ item: VaultItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].isFavorite.toggle()
            saveIndex()
        }
    }

    func setFavorite(_ ids: Set<UUID>, _ value: Bool) {
        for id in ids {
            if let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx].isFavorite = value
            }
        }
        saveIndex()
    }

    // MARK: - 删除系统相册原图
    private func deleteOriginals(with identifiers: [String]) async {
        let granted = await ensureLibraryAccess()
        guard granted else {
            lastError = "未获得完整相册访问权限，原图未删除。请在 设置-隐私与安全性-照片 中把『闲阅』权限改为『所有照片』后重试"
            return
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
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

    func restoreItems(_ ids: Set<UUID>) {
        for id in ids {
            if let item = items.first(where: { $0.id == id }) {
                restore(item)
            }
        }
    }

    // MARK: - 删除
    func delete(_ item: VaultItem) {
        try? FileManager.default.removeItem(at: item.fileURL)
        items.removeAll { $0.id == item.id }
        saveIndex()
    }

    func deleteItems(_ ids: Set<UUID>) {
        for id in ids {
            if let item = items.first(where: { $0.id == id }) {
                try? FileManager.default.removeItem(at: item.fileURL)
            }
        }
        items.removeAll { ids.contains($0.id) }
        saveIndex()
    }

    // MARK: - 权限
    func ensureLibraryAccess() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized:
            return true
        case .limited:
            return false
        case .notDetermined:
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite) == .authorized
        default:
            return false
        }
    }
}
