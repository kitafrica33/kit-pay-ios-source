import XCTest
@testable import KitPay

/// Pins the referral client to backend PR #92's wire contract: the exact capability gate, the
/// closed coarse status set, strict money/terms/link validation, and the totals coherence rule.
/// Everything policy-shaped (amounts, day counts) must come from the payload — these tests also
/// prove malformed payloads fail the decode closed instead of rendering guesses.
final class ReferralContractTests: XCTestCase {
    // MARK: - Gate

    func testReferralGateRequiresExactAdvertisedCapability() {
        XCTAssertEqual(ReferralGate.state(features: nil), .unavailable)
        XCTAssertEqual(ReferralGate.state(features: [:]), .unavailable)
        XCTAssertEqual(ReferralGate.state(features: ["referrals": false]), .unavailable)
        // An explicit JSON null is not true.
        XCTAssertEqual(ReferralGate.state(features: ["referrals": Bool?.none]), .unavailable)
        // Other capabilities do not leak into this gate.
        XCTAssertEqual(
            ReferralGate.state(features: ["support": true, "wallets": true]),
            .unavailable
        )
        XCTAssertEqual(ReferralGate.state(features: ["referrals": true]), .available)
        XCTAssertFalse(ReferralGateState.unavailable.isAvailable)
        XCTAssertTrue(ReferralGateState.available.isAvailable)
    }

    func testClientPolicyPins() {
        XCTAssertEqual(ReferralContract.capabilityKey, "referrals")
        XCTAssertEqual(
            ReferralContract.knownStatuses,
            ["pending", "qualified", "paid", "expired", "not_eligible", "reversed"]
        )
        XCTAssertEqual(ReferralAPIEndpoint.overview.path, "referrals")
        XCTAssertEqual(ReferralAPIEndpoint.overview.method, "GET")
        XCTAssertEqual(ReferralAPIEndpoint.ensureCode.path, "referrals/code")
        XCTAssertEqual(ReferralAPIEndpoint.ensureCode.method, "POST")
    }

    // MARK: - Fixtures

    private let programJSON = """
        {"reward": {"amount": "25000.00", "currency": {"code": "UGX", "scale": "2"}},
         "qualifying_balance": {"amount": "1000000.00",
                                "currency": {"code": "UGX", "scale": "2"}},
         "qualifying_business_days": 1, "window_days": 90}
        """

    private let codeJSON = """
        {"code": "KIT8H2XQ4", "share_url": "https://kitpay.app/r/KIT8H2XQ4"}
        """

    private func itemJSON(
        id: String = "77777777-7777-4777-8777-777777777777",
        referredName: String = "\"Asha N.\"",
        status: String = "pending",
        paidAt: String = "null"
    ) -> String {
        """
        {"id": "\(id)", "referred_name": \(referredName), "status": "\(status)",
         "reward": {"amount": "25000.00", "currency": {"code": "UGX", "scale": "2"}},
         "attributed_at": "2026-08-27T10:00:00Z", "paid_at": \(paidAt)}
        """
    }

    private func overviewJSON(
        program: String? = nil,
        code: String? = nil,
        referrals: String = "[]",
        totals: String = """
            {"total": 0, "pending": 0, "qualified": 0, "paid": 0, "expired": 0,
             "not_eligible": 0, "reversed": 0}
            """
    ) -> String {
        """
        {"program": \(program ?? "null"), "code": \(code ?? "null"),
         "referrals": \(referrals), "totals": \(totals)}
        """
    }

    private func decodeOverview(_ json: String) throws -> ReferralOverviewDTO {
        try JSONDecoder().decode(ReferralOverviewDTO.self, from: Data(json.utf8))
    }

    private func decodeMoney(_ json: String) throws -> ReferralMoneyDTO {
        try JSONDecoder().decode(ReferralMoneyDTO.self, from: Data(json.utf8))
    }

    private func moneyJSON(
        amount: String = "25000.00",
        code: String = "UGX",
        scale: String = "2"
    ) -> String {
        """
        {"amount": "\(amount)", "currency": {"code": "\(code)", "scale": "\(scale)"}}
        """
    }

    // MARK: - Overview decode

    func testDecodesFullOverviewFromServerPayload() throws {
        let paid = itemJSON(
            id: "88888888-8888-4888-8888-888888888888",
            status: "paid",
            paidAt: "\"2026-08-28T09:00:00Z\""
        )
        let overview = try decodeOverview(
            overviewJSON(
                program: programJSON,
                code: codeJSON,
                referrals: "[\(itemJSON()), \(paid)]",
                totals: """
                    {"total": 2, "pending": 1, "qualified": 0, "paid": 1, "expired": 0,
                     "not_eligible": 0, "reversed": 0}
                    """
            )
        )

        let program = try XCTUnwrap(overview.program)
        XCTAssertEqual(program.reward.amount, "25000.00")
        XCTAssertEqual(program.reward.currencyCode, "UGX")
        XCTAssertEqual(program.reward.currencyScale, 2)
        XCTAssertEqual(program.qualifyingBalance.amount, "1000000.00")
        XCTAssertEqual(program.qualifyingBusinessDays, 1)
        XCTAssertEqual(program.windowDays, 90)

        let code = try XCTUnwrap(overview.code)
        XCTAssertEqual(code.code, "KIT8H2XQ4")
        XCTAssertEqual(code.shareURL.absoluteString, "https://kitpay.app/r/KIT8H2XQ4")

        XCTAssertEqual(overview.referrals.count, 2)
        XCTAssertEqual(overview.referrals[0].referredName, "Asha N.")
        XCTAssertEqual(overview.referrals[0].status, "pending")
        XCTAssertNil(overview.referrals[0].paidAt)
        XCTAssertEqual(overview.referrals[1].status, "paid")
        XCTAssertEqual(overview.referrals[1].paidAt, "2026-08-28T09:00:00Z")
        XCTAssertEqual(overview.totals.total, 2)
        XCTAssertEqual(overview.totals.paid, 1)
    }

    func testDecodesDarkAndEmptyOverview() throws {
        // No active policy and no minted code are both legitimate: nothing may be promised.
        let overview = try decodeOverview(overviewJSON())
        XCTAssertNil(overview.program)
        XCTAssertNil(overview.code)
        XCTAssertTrue(overview.referrals.isEmpty)
        XCTAssertEqual(overview.totals.total, 0)
    }

    func testNullableReferredNameAndPaidAtDecode() throws {
        let overview = try decodeOverview(
            overviewJSON(
                referrals: "[\(itemJSON(referredName: "null"))]",
                totals: """
                    {"total": 1, "pending": 1, "qualified": 0, "paid": 0, "expired": 0,
                     "not_eligible": 0, "reversed": 0}
                    """
            )
        )
        XCTAssertNil(overview.referrals[0].referredName)
        XCTAssertNil(overview.referrals[0].paidAt)
    }

    // MARK: - Closed status set

    func testUnknownStatusFailsClosed() {
        // "review" is an INTERNAL state the backend deliberately collapses to "pending";
        // seeing it (or anything else off-contract) on the wire is a contract break.
        for status in ["review", "payable", "PENDING", " pending", "settled", ""] {
            XCTAssertThrowsError(
                try decodeOverview(
                    overviewJSON(
                        referrals: "[\(itemJSON(status: status))]",
                        totals: """
                            {"total": 1, "pending": 1, "qualified": 0, "paid": 0,
                             "expired": 0, "not_eligible": 0, "reversed": 0}
                            """
                    )
                ),
                "status '\(status)' must fail closed"
            )
        }
    }

    // MARK: - Totals coherence

    func testTotalsMustMatchBucketSum() {
        XCTAssertThrowsError(
            try decodeOverview(
                overviewJSON(
                    totals: """
                        {"total": 3, "pending": 1, "qualified": 0, "paid": 1, "expired": 0,
                         "not_eligible": 0, "reversed": 0}
                        """
                )
            )
        )
        XCTAssertThrowsError(
            try decodeOverview(
                overviewJSON(
                    totals: """
                        {"total": -1, "pending": -1, "qualified": 0, "paid": 0, "expired": 0,
                         "not_eligible": 0, "reversed": 0}
                        """
                )
            )
        )
    }

    // MARK: - Money validation

    func testMoneyDecodesCoherentServerFormats() throws {
        XCTAssertEqual(try decodeMoney(moneyJSON()).amount, "25000.00")
        XCTAssertEqual(try decodeMoney(moneyJSON(amount: "0.50")).amount, "0.50")
        let wholeUnits = try decodeMoney(moneyJSON(amount: "123", scale: "0"))
        XCTAssertEqual(wholeUnits.currencyScale, 0)
    }

    func testMoneyRejectsIncoherentPayloads() {
        // The server never sends grouping, signs, or non-decimal text.
        for amount in ["25,000.00", "-5.00", "", "1.2.3", "abc", "١٢٣", ".50", "5."] {
            XCTAssertThrowsError(
                try decodeMoney(moneyJSON(amount: amount)),
                "amount '\(amount)' must fail closed"
            )
        }
        for code in ["ugx", "UGXX", "UG", "UG1", ""] {
            XCTAssertThrowsError(
                try decodeMoney(moneyJSON(code: code)),
                "currency code '\(code)' must fail closed"
            )
        }
        for scale in ["x", "99", "-1", ""] {
            XCTAssertThrowsError(
                try decodeMoney(moneyJSON(scale: scale)),
                "scale '\(scale)' must fail closed"
            )
        }
    }

    // MARK: - Program terms validation

    func testProgramTermsRejectIncoherentDayCounts() {
        func terms(businessDays: Int, windowDays: Int) -> String {
            overviewJSON(
                program: """
                    {"reward": \(moneyJSON()), "qualifying_balance": \(moneyJSON()),
                     "qualifying_business_days": \(businessDays), "window_days": \(windowDays)}
                    """
            )
        }
        XCTAssertThrowsError(try decodeOverview(terms(businessDays: 0, windowDays: 90)))
        XCTAssertThrowsError(try decodeOverview(terms(businessDays: 1, windowDays: 0)))
        XCTAssertThrowsError(try decodeOverview(terms(businessDays: 1, windowDays: 5000)))
        XCTAssertNoThrow(try decodeOverview(terms(businessDays: 1, windowDays: 90)))
    }

    // MARK: - Share link validation

    func testShareCodeRequiresHTTPSLinkWithHost() {
        func codePayload(code: String = "KIT8H2XQ4", url: String) -> String {
            overviewJSON(code: "{\"code\": \"\(code)\", \"share_url\": \"\(url)\"}")
        }
        XCTAssertThrowsError(
            try decodeOverview(codePayload(url: "http://kitpay.app/r/KIT8H2XQ4"))
        )
        XCTAssertThrowsError(try decodeOverview(codePayload(url: "https://")))
        XCTAssertThrowsError(try decodeOverview(codePayload(url: "kitpay.app/r/x")))
        XCTAssertThrowsError(try decodeOverview(codePayload(url: "")))
        XCTAssertThrowsError(
            try decodeOverview(
                codePayload(code: "", url: "https://kitpay.app/r/x")
            )
        )
        XCTAssertThrowsError(
            try decodeOverview(
                codePayload(
                    code: String(repeating: "K", count: 65),
                    url: "https://kitpay.app/r/x"
                )
            )
        )
        XCTAssertNoThrow(
            try decodeOverview(codePayload(url: "https://kitpay.app/r/KIT8H2XQ4"))
        )
    }

    // MARK: - List integrity

    func testListItemRequiresCanonicalIdentityAndTimestamps() {
        XCTAssertThrowsError(
            try decodeOverview(
                overviewJSON(
                    referrals: "[\(itemJSON(id: "not-a-uuid"))]",
                    totals: """
                        {"total": 1, "pending": 1, "qualified": 0, "paid": 0, "expired": 0,
                         "not_eligible": 0, "reversed": 0}
                        """
                )
            )
        )
        XCTAssertThrowsError(
            try decodeOverview(
                overviewJSON(
                    referrals: "[\(itemJSON(referredName: "\"\""))]",
                    totals: """
                        {"total": 1, "pending": 1, "qualified": 0, "paid": 0, "expired": 0,
                         "not_eligible": 0, "reversed": 0}
                        """
                )
            )
        )
    }

    func testOverviewRejectsDuplicateAndOverlongLists() throws {
        let duplicated = "[\(itemJSON()), \(itemJSON())]"
        XCTAssertThrowsError(
            try decodeOverview(
                overviewJSON(
                    referrals: duplicated,
                    totals: """
                        {"total": 2, "pending": 2, "qualified": 0, "paid": 0, "expired": 0,
                         "not_eligible": 0, "reversed": 0}
                        """
                )
            )
        )

        // 101 distinct rows exceed the server's own cap and are incoherent.
        let rows = (0..<101).map { index -> String in
            let suffix = String(format: "%012d", index)
            return itemJSON(id: "99999999-9999-4999-8999-\(suffix)")
        }
        XCTAssertThrowsError(
            try decodeOverview(
                overviewJSON(
                    referrals: "[\(rows.joined(separator: ","))]",
                    totals: """
                        {"total": 101, "pending": 101, "qualified": 0, "paid": 0,
                         "expired": 0, "not_eligible": 0, "reversed": 0}
                        """
                )
            )
        )
    }

    // MARK: - ensureCode response

    func testDecodesEnsureCodeResponse() throws {
        let response = try JSONDecoder().decode(
            ReferralCodeResponseDTO.self,
            from: Data("{\"code\": \(codeJSON)}".utf8)
        )
        XCTAssertEqual(response.code.code, "KIT8H2XQ4")
        XCTAssertEqual(
            response.code.shareURL.absoluteString,
            "https://kitpay.app/r/KIT8H2XQ4"
        )
    }
}
