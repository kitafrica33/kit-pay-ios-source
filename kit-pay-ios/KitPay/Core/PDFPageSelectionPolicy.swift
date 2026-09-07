import Foundation

/// User-facing page numbers are one-based; PDFKit and the returned indexes are zero-based.
enum PDFPageSelectionPolicy {
    static let maximumPageCount = 10_000
    static let maximumExpressionLength = 4_096

    enum SelectionError: LocalizedError, Equatable {
        case unsupportedPageCount
        case emptySelection
        case expressionTooLong
        case invalidRange
        case pageOutOfBounds

        var errorDescription: String? {
            switch self {
            case .unsupportedPageCount:
                return "Choose a PDF with between 1 and 10,000 pages."
            case .emptySelection:
                return "Select at least one page."
            case .expressionTooLong:
                return "Use shorter page ranges, such as 1–10, 15."
            case .invalidRange:
                return "Enter page numbers or ranges, such as 1–3, 5."
            case .pageOutOfBounds:
                return "Choose page numbers within this document."
            }
        }
    }

    static func allPages(pageCount: Int) throws -> IndexSet {
        try validatePageCount(pageCount)
        return IndexSet(integersIn: 0..<pageCount)
    }

    /// Unsorted, repeated and overlapping ranges are combined in original document order.
    /// Never silently discard an invalid page: that could send a different selection.
    static func pageIndexes(from expression: String, pageCount: Int) throws -> IndexSet {
        try validatePageCount(pageCount)
        guard expression.utf8.count <= maximumExpressionLength else {
            throw SelectionError.expressionTooLong
        }
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw SelectionError.emptySelection }

        let normalized = text
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
        var indexes = IndexSet()
        for component in normalized.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = component.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 1 || bounds.count == 2 else {
                throw SelectionError.invalidRange
            }
            let first = try pageNumber(bounds[0], pageCount: pageCount)
            let last: Int
            if bounds.count == 2 {
                last = try pageNumber(bounds[1], pageCount: pageCount)
            } else {
                last = first
            }
            guard first <= last else { throw SelectionError.invalidRange }
            indexes.insert(integersIn: (first - 1)..<last)
        }
        return try validatedPageIndexes(indexes, pageCount: pageCount)
    }

    static func validatedPageIndexes(_ indexes: IndexSet, pageCount: Int) throws -> IndexSet {
        try validatePageCount(pageCount)
        guard !indexes.isEmpty else { throw SelectionError.emptySelection }
        guard indexes.first.map({ $0 >= 0 }) == true,
              indexes.last.map({ $0 < pageCount }) == true
        else { throw SelectionError.pageOutOfBounds }
        return indexes
    }

    /// Compact text for selections made with the preview's include/exclude button.
    static func expression(for indexes: IndexSet) -> String {
        indexes.rangeView.map { range in
            let first = range.lowerBound + 1
            let last = range.upperBound
            return first == last ? "\(first)" : "\(first)-\(last)"
        }.joined(separator: ", ")
    }

    private static func validatePageCount(_ pageCount: Int) throws {
        guard (1...maximumPageCount).contains(pageCount) else {
            throw SelectionError.unsupportedPageCount
        }
    }

    private static func pageNumber(_ component: Substring, pageCount: Int) throws -> Int {
        let text = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(text)
        else { throw SelectionError.invalidRange }
        guard (1...pageCount).contains(number) else { throw SelectionError.pageOutOfBounds }
        return number
    }
}
