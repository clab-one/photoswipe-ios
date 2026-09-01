import Photos

// FOLIO 변경: `byteSize(of:)` / `totalBytes(of:)` 를 제거했다.
// 원본 주석 스스로 "undocumented `fileSize` via KVC ... strip or replace before
// any App Store submission" 이라고 적어 두었다. FOLIO 는 App Store 에 올리고,
// 저장 용량 정리는 PhotoSwipe 의 제품이지 FOLIO 의 것이 아니다.
//
// 원본: https://github.com/noluyorAbi/photoswipe-ios  (MIT)
import UIKit

/// Thin wrapper over PhotoKit: authorization, fetching the newest-first asset
/// stream, image loading, and the mutating operations (favorite, album,
/// batch delete). All mutations go through `PHPhotoLibrary.performChanges`.
final class PhotoLibraryService {
    private let imageManager = PHCachingImageManager()

    // MARK: Authorization

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status)
            }
        }
    }

    // MARK: Fetch

    /// All image assets, newest first.
    func fetchAllPhotos() -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    // MARK: Image loading

    func requestImage(for asset: PHAsset, targetSize: CGSize,
                      contentMode: PHImageContentMode = .aspectFill) async -> UIImage? {
        await withCheckedContinuation { cont in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: contentMode,
                options: options
            ) { image, info in
                if resumed { return }
                // Opportunistic delivers a degraded placeholder first, then a
                // single non-degraded final callback (image OR nil on error /
                // failed iCloud fetch). Resume on the final one regardless, so
                // a nil result can never leak the continuation.
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if degraded { return }   // wait for the final callback
                resumed = true
                cont.resume(returning: image)
            }
        }
    }

    // MARK: File size

    func startCaching(_ assets: [PHAsset], targetSize: CGSize) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        imageManager.startCachingImages(for: assets, targetSize: targetSize,
                                        contentMode: .aspectFill, options: options)
    }

    /// Drop all prefetched images — call when leaving a deck to bound memory.
    func stopCaching() {
        imageManager.stopCachingImagesForAllAssets()
    }

    // MARK: Mutations

    func setFavorite(_ asset: PHAsset, _ favorite: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetChangeRequest(for: asset)
            req.isFavorite = favorite
        }
    }

    func deleteAssets(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    // MARK: Albums

    func userAlbums() -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: nil)
        var albums: [PHAssetCollection] = []
        result.enumerateObjects { c, _, _ in albums.append(c) }
        return albums
    }

    func album(withLocalIdentifier id: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [id], options: nil).firstObject
    }

    func createAlbum(named title: String) async throws -> String {
        var localId = ""
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            localId = req.placeholderForCreatedAssetCollection.localIdentifier
        }
        return localId
    }

    func add(_ asset: PHAsset, toAlbumWithLocalIdentifier id: String) async throws {
        guard let collection = album(withLocalIdentifier: id) else { return }
        try await PHPhotoLibrary.shared().performChanges {
            guard let req = PHAssetCollectionChangeRequest(for: collection) else { return }
            req.addAssets([asset] as NSArray)
        }
    }
}
