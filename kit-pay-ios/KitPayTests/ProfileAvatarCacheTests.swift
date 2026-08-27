import UIKit
import XCTest
@testable import KitPay

final class ProfileAvatarCacheTests: XCTestCase {
    // MARK: - URL validation

    func testOnlyHTTPSAvatarURLsAreAccepted() {
        XCTAssertNotNil(ProfileAvatarCache.validatedURL("https://cdn.kit.africa/a/1.jpg"))
        XCTAssertNotNil(ProfileAvatarCache.validatedURL("HTTPS://cdn.kit.africa/a/1.jpg"))
        // Plaintext, local files and anything that can drive a handler are all rejected before a
        // URLSession or the filesystem ever sees the string.
        XCTAssertNil(ProfileAvatarCache.validatedURL("http://cdn.kit.africa/a/1.jpg"))
        XCTAssertNil(ProfileAvatarCache.validatedURL("file:///etc/passwd"))
        XCTAssertNil(ProfileAvatarCache.validatedURL("kitpay://profile"))
        XCTAssertNil(ProfileAvatarCache.validatedURL("https:///no-host.jpg"))
        XCTAssertNil(ProfileAvatarCache.validatedURL("   "))
        XCTAssertNil(ProfileAvatarCache.validatedURL(nil))
    }

    func testSurroundingWhitespaceDoesNotDefeatValidation() {
        let url = ProfileAvatarCache.validatedURL("  https://cdn.kit.africa/a/1.jpg\n")
        XCTAssertEqual(url?.absoluteString, "https://cdn.kit.africa/a/1.jpg")
    }

    // MARK: - Cache keys

    func testCacheKeysAreStableLowercaseHexDigests() throws {
        let url = try XCTUnwrap(ProfileAvatarCache.validatedURL("https://cdn.kit.africa/a/1.jpg"))
        let key = ProfileAvatarCache.cacheKey(for: url)
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        // Stability matters across launches: a key derived from a per-launch hash would orphan
        // every file already on disk.
        XCTAssertEqual(key, ProfileAvatarCache.cacheKey(for: url))
    }

    func testDifferentAvatarsGetDifferentKeys() throws {
        let first = try XCTUnwrap(ProfileAvatarCache.validatedURL("https://cdn.kit.africa/a/1.jpg"))
        let second = try XCTUnwrap(ProfileAvatarCache.validatedURL("https://cdn.kit.africa/a/2.jpg"))
        XCTAssertNotEqual(
            ProfileAvatarCache.cacheKey(for: first),
            ProfileAvatarCache.cacheKey(for: second)
        )
    }

    // MARK: - Memory cache

    func testMemoryCacheServesTheSameURLWithoutAnAwait() throws {
        let memory = ProfileAvatarMemoryCache()
        let url = try XCTUnwrap(ProfileAvatarCache.validatedURL("https://cdn.kit.africa/a/1.jpg"))
        let key = ProfileAvatarCache.cacheKey(for: url)
        let image = try makeImage()

        XCTAssertNil(memory.image(forKey: key))
        memory.insert(image, forKey: key)
        XCTAssertIdentical(memory.image(forKey: key), image)

        // Sign-out and account switches both go through this; a face must never outlive the
        // session it belonged to.
        memory.removeAll()
        XCTAssertNil(memory.image(forKey: key))
    }

    func testCachedImageLookupRejectsAnUncacheableURL() throws {
        let image = try makeImage()
        ProfileAvatarMemoryCache.shared.insert(image, forKey: "not-a-digest")
        defer { ProfileAvatarMemoryCache.shared.removeAll() }
        XCTAssertNil(ProfileAvatarCache.cachedImage(for: "http://cdn.kit.africa/a/1.jpg"))
        XCTAssertNil(ProfileAvatarCache.cachedImage(for: nil))
    }

    func testCachedImageLookupReturnsWhatTheCacheHolds() throws {
        let image = try makeImage()
        let raw = "https://cdn.kit.africa/a/lookup.jpg"
        let url = try XCTUnwrap(ProfileAvatarCache.validatedURL(raw))
        ProfileAvatarMemoryCache.shared.insert(image, forKey: ProfileAvatarCache.cacheKey(for: url))
        defer { ProfileAvatarMemoryCache.shared.removeAll() }
        XCTAssertIdentical(ProfileAvatarCache.cachedImage(for: raw), image)
    }

    private func makeImage() throws -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }
}
