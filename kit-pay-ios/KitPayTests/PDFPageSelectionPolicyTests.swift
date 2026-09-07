import PDFKit
import UIKit
import XCTest
@testable import KitPay

final class PDFPageSelectionPolicyTests: XCTestCase {
    func testUnsortedOverlappingRangesPreserveDocumentOrderWithoutDuplicates() throws {
        let selected = try PDFPageSelectionPolicy.pageIndexes(from: "5, 2-4, 1, 3-5", pageCount: 8)
        XCTAssertEqual(Array(selected), [0, 1, 2, 3, 4])
        XCTAssertEqual(PDFPageSelectionPolicy.expression(for: selected), "1-5")
    }

    func testWhitespaceAndKeyboardDashVariantsAreAccepted() throws {
        let selected = try PDFPageSelectionPolicy.pageIndexes(from: " 2 – 3,\n5—6 , 8 ", pageCount: 8)
        XCTAssertEqual(Array(selected), [1, 2, 4, 5, 7])
        XCTAssertEqual(PDFPageSelectionPolicy.expression(for: selected), "2-3, 5-6, 8")
    }

    func testInvalidAndOutOfBoundsPagesNeverSilentlyBecomeAPartialSelection() {
        for expression in ["", " ", "0", "4", "1,4", "3-2", "1-", "-2", "1-2-3", "1,,2", ",1", "1,", "1.5", "+1", "1 2", "one", "١", "999999999999999999999999"] {
            XCTAssertThrowsError(
                try PDFPageSelectionPolicy.pageIndexes(from: expression, pageCount: 3),
                expression
            )
        }
    }

    func testSelectionCountAndExpressionLengthAreBounded() throws {
        XCTAssertEqual(try PDFPageSelectionPolicy.allPages(pageCount: 1), IndexSet(integer: 0))
        XCTAssertEqual(
            try PDFPageSelectionPolicy.allPages(pageCount: PDFPageSelectionPolicy.maximumPageCount).count,
            PDFPageSelectionPolicy.maximumPageCount
        )
        for count in [-1, 0, PDFPageSelectionPolicy.maximumPageCount + 1] {
            XCTAssertThrowsError(try PDFPageSelectionPolicy.allPages(pageCount: count))
        }
        XCTAssertThrowsError(try PDFPageSelectionPolicy.pageIndexes(
            from: String(repeating: "1", count: PDFPageSelectionPolicy.maximumExpressionLength + 1),
            pageCount: 1
        )) { error in
            XCTAssertEqual(error as? PDFPageSelectionPolicy.SelectionError, .expressionTooLong)
        }
    }

    func testExportSelectionMustBeNonemptyAndInsideTheActualDocument() {
        XCTAssertThrowsError(try PDFPageSelectionPolicy.validatedPageIndexes(IndexSet(), pageCount: 3))
        XCTAssertThrowsError(try PDFPageSelectionPolicy.validatedPageIndexes(IndexSet([0, 3]), pageCount: 3))
    }

    func testSelectionTextRoundTripsAfterTogglingAPreviewPage() throws {
        var selected = try PDFPageSelectionPolicy.allPages(pageCount: 6)
        selected.remove(2)
        selected.remove(4)
        let expression = PDFPageSelectionPolicy.expression(for: selected)
        XCTAssertEqual(expression, "1-2, 4, 6")
        XCTAssertEqual(try PDFPageSelectionPolicy.pageIndexes(from: expression, pageCount: 6), selected)
        XCTAssertEqual(PDFPageSelectionPolicy.expression(for: IndexSet()), "")
    }

    @MainActor
    func testExportCopiesOnlySelectedPagesToAnIndependentlyOwnedProtectedPDF() throws {
        let sourceData = makeThreePagePDF()
        let source = try ChatMediaTempFiles.writeTemporaryFile(
            data: sourceData,
            mediaType: "application/pdf",
            suggestedName: "Original.pdf"
        )
        defer { ChatMediaTempFiles.removeTemporaryFile(source) }
        let selected = try KitPDFPageSelectionExporter.export(
            fileURL: source,
            displayName: "Original.pdf",
            pageIndexes: IndexSet([0, 2])
        )
        defer { ChatMediaTempFiles.removeTemporaryFile(selected) }

        XCTAssertNotEqual(selected, source)
        XCTAssertNotEqual(selected.deletingLastPathComponent(), source.deletingLastPathComponent())
        XCTAssertEqual(selected.pathExtension, "pdf")
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
        XCTAssertEqual(PDFDocument(url: source)?.pageCount, 3)
        let exported = try XCTUnwrap(PDFDocument(url: selected))
        XCTAssertEqual(exported.pageCount, 2)
        XCTAssertTrue(exported.page(at: 0)?.string?.contains("Original page 1") == true)
        XCTAssertTrue(exported.page(at: 1)?.string?.contains("Original page 3") == true)

        let attributes = try FileManager.default.attributesOfItem(atPath: selected.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        if let protection = attributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUnlessOpen)
        }
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: selected.deletingLastPathComponent().path
        )
        if let protection = directoryAttributes[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(protection, .completeUnlessOpen)
        }
        ChatMediaTempFiles.removeTemporaryFile(selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
    }

    @MainActor
    func testExportRejectsInvalidSelectionWithoutChangingTheOriginal() throws {
        let original = makeThreePagePDF()
        let source = try ChatMediaTempFiles.writeTemporaryFile(data: original, mediaType: "application/pdf")
        defer { ChatMediaTempFiles.removeTemporaryFile(source) }
        for selection in [IndexSet(), IndexSet(integer: 3)] {
            XCTAssertThrowsError(try KitPDFPageSelectionExporter.export(
                fileURL: source,
                displayName: "Original.pdf",
                pageIndexes: selection
            ))
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor
    func testCancellationAfterWritingRemovesScratchOutputAndPreservesTheOriginal() async throws {
        let original = makeThreePagePDF()
        let source = try ChatMediaTempFiles.writeTemporaryFile(data: original, mediaType: "application/pdf")
        defer { ChatMediaTempFiles.removeTemporaryFile(source) }
        var preparedOutput: URL?
        var preparedOutputHadBytes = false
        let worker = Task { @MainActor in
            try KitPDFPageSelectionExporter.export(
                fileURL: source,
                displayName: "Original.pdf",
                pageIndexes: IndexSet([0, 2]),
                beforePublishing: { output in
                    preparedOutput = output
                    preparedOutputHadBytes = ((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        do {
            _ = try await worker.value
            XCTFail("A cancelled export must not publish its scratch URL")
        } catch is CancellationError {
            // Expected after PDFKit has produced real output but before ownership transfer.
        }
        let output = try XCTUnwrap(preparedOutput)
        XCTAssertTrue(preparedOutputHadBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    @MainActor
    private func makeThreePagePDF() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            for page in 1...3 {
                context.beginPage()
                ("Original page \(page)" as NSString).draw(
                    at: CGPoint(x: 20, y: 20),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 18)]
                )
            }
        }
    }
}
