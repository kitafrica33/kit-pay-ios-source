import XCTest
@testable import KitPay

/// The arithmetic a customer would otherwise have to do in their head at the moment a payment is
/// refused: how far short the balance is, and what to top up.
final class WalletTopUpTests: XCTestCase {
    private func wallet(
        id: String = "wallet-1",
        available: String,
        code: String = "UGX",
        scale: String = "2"
    ) -> Wallet {
        Wallet(
            id: id,
            name: "Primary wallet",
            accountNumber: "0000000000",
            accountType: "personal",
            currency: CurrencyDTO(code: code, scale: scale),
            balances: WalletBalances(available: available, ledger: available),
            status: "active",
            isPrimary: true
        )
    }

    func testNoRequirementWhenTheBalanceCoversThePayment() {
        XCTAssertNil(WalletTopUpPolicy.requirement(
            wallet: wallet(available: "10000.00"),
            debitAPIAmount: "10000.00"
        ))
        XCTAssertNil(WalletTopUpPolicy.requirement(
            wallet: wallet(available: "10000.00"),
            debitAPIAmount: "9999.99"
        ))
    }

    func testShortfallIsRoundedUpToTheNextWholeUnit() throws {
        let requirement = try XCTUnwrap(WalletTopUpPolicy.requirement(
            wallet: wallet(available: "800.50"),
            debitAPIAmount: "5000.75"
        ))
        XCTAssertEqual(requirement.shortfallAPIAmount, "4200.25")
        XCTAssertEqual(requirement.suggestedTopUpAPIAmount, "4201.00")
        XCTAssertEqual(requirement.requiredAPIAmount, "5000.75")
        XCTAssertEqual(requirement.walletID, "wallet-1")
    }

    func testAWholeShortfallIsNotInflated() throws {
        let requirement = try XCTUnwrap(WalletTopUpPolicy.requirement(
            wallet: wallet(available: "1000.00"),
            debitAPIAmount: "6000.00"
        ))
        XCTAssertEqual(requirement.shortfallAPIAmount, "5000.00")
        XCTAssertEqual(requirement.suggestedTopUpAPIAmount, "5000.00")
    }

    /// Nobody can send a mobile money request for one cent; the smallest useful top-up is a unit.
    func testATinyShortfallStillAsksForOneWholeUnit() throws {
        let requirement = try XCTUnwrap(WalletTopUpPolicy.requirement(
            wallet: wallet(available: "999.99"),
            debitAPIAmount: "1000.00"
        ))
        XCTAssertEqual(requirement.shortfallAPIAmount, "0.01")
        XCTAssertEqual(requirement.suggestedTopUpAPIAmount, "1.00")
    }

    /// The rails that charge a fee debit more than the amount typed. A top-up sized to the amount
    /// alone would leave the payment failing a second time.
    func testTheTransactionFeeIsPartOfTheShortfall() throws {
        let balance = wallet(available: "10000.00")
        XCTAssertNil(WalletTopUpPolicy.requirement(
            wallet: balance,
            debitAPIAmount: "10000.00"
        ))
        let requirement = try XCTUnwrap(WalletTopUpPolicy.requirement(
            wallet: balance,
            debitAPIAmount: "10300.00"
        ))
        XCTAssertEqual(requirement.shortfallAPIAmount, "300.00")
        XCTAssertEqual(requirement.suggestedTopUpAPIAmount, "300.00")
    }

    func testNoRequirementWithoutAWalletOrAUsableDebit() {
        XCTAssertNil(WalletTopUpPolicy.requirement(wallet: nil, debitAPIAmount: "1000.00"))
        let balance = wallet(available: "0.00")
        XCTAssertNil(WalletTopUpPolicy.requirement(wallet: balance, debitAPIAmount: nil))
        XCTAssertNil(WalletTopUpPolicy.requirement(wallet: balance, debitAPIAmount: ""))
        XCTAssertNil(WalletTopUpPolicy.requirement(wallet: balance, debitAPIAmount: "   "))
        XCTAssertNil(WalletTopUpPolicy.requirement(wallet: balance, debitAPIAmount: "abc"))
        XCTAssertNil(WalletTopUpPolicy.requirement(wallet: balance, debitAPIAmount: "0.00"))
    }

    /// An unreadable balance must not read as "you have enough" — the shortfall is measured
    /// against zero instead.
    func testAnUnreadableBalanceCountsAsNothingAvailable() throws {
        let requirement = try XCTUnwrap(WalletTopUpPolicy.requirement(
            wallet: wallet(available: "not-a-number"),
            debitAPIAmount: "2500.00"
        ))
        XCTAssertEqual(requirement.shortfallAPIAmount, "2500.00")
    }

    func testCoverageNeedsTheSameWalletAndEnoughMoney() throws {
        let requirement = try XCTUnwrap(WalletTopUpPolicy.requirement(
            wallet: wallet(available: "800.00"),
            debitAPIAmount: "5000.00"
        ))
        XCTAssertFalse(requirement.isCovered(by: nil))
        XCTAssertFalse(requirement.isCovered(by: wallet(available: "800.00")))
        XCTAssertFalse(requirement.isCovered(by: wallet(available: "4999.99")))
        XCTAssertTrue(requirement.isCovered(by: wallet(available: "5000.00")))
        XCTAssertTrue(requirement.isCovered(by: wallet(available: "9000.00")))
        // A different wallet being topped up never releases this payment.
        XCTAssertFalse(requirement.isCovered(by: wallet(id: "wallet-2", available: "9000.00")))
    }

    func testAmountsAreWrittenAtTheCurrencyScale() {
        XCTAssertEqual(WalletTopUpPolicy.apiAmount(Decimal(4201), scale: 0), "4201")
        XCTAssertEqual(WalletTopUpPolicy.apiAmount(Decimal(4201), scale: 2), "4201.00")
        XCTAssertEqual(WalletTopUpPolicy.apiAmount(Decimal(string: "0.5")!, scale: 2), "0.50")
        XCTAssertEqual(WalletTopUpPolicy.apiAmount(Decimal(-5), scale: 2), "0.00")
    }

    /// Balances arriving grouped (or with stray whitespace) must still read as money.
    func testGroupedAmountsAreStillReadable() {
        XCTAssertEqual(WalletTopUpPolicy.decimal(" 1,200.50 "), Decimal(string: "1200.50"))
        XCTAssertNil(WalletTopUpPolicy.decimal(nil))
        XCTAssertNil(WalletTopUpPolicy.decimal(""))
    }

    func testZeroScaleCurrencyKeepsWholeAmounts() throws {
        let requirement = try XCTUnwrap(WalletTopUpPolicy.requirement(
            wallet: wallet(available: "800", scale: "0"),
            debitAPIAmount: "5000"
        ))
        XCTAssertEqual(requirement.shortfallAPIAmount, "4200")
        XCTAssertEqual(requirement.suggestedTopUpAPIAmount, "4200")
    }

    func testTheSummaryStatesTheShortfallAsMoney() throws {
        let requirement = try XCTUnwrap(WalletTopUpPolicy.requirement(
            wallet: wallet(available: "800.00"),
            debitAPIAmount: "5000.00"
        ))
        XCTAssertEqual(
            requirement.displayShortfall,
            KitMoney.formatted("4200.00", code: "UGX", scale: 2, trimZeroFraction: true)
        )
        XCTAssertTrue(requirement.summary.contains(requirement.displayShortfall))
        XCTAssertTrue(requirement.displayShortfall.hasPrefix("UGX "))
        XCTAssertFalse(requirement.displayShortfall.contains(".00"))
    }

    func testOnlyTheServersOwnInsufficientFundsCodeOffersATopUp() {
        XCTAssertTrue(WalletTopUpPolicy.isInsufficientFunds(
            APIErrorPayload(code: "INSUFFICIENT_FUNDS", message: "Insufficient funds", httpStatus: 409)
        ))
        XCTAssertFalse(WalletTopUpPolicy.isInsufficientFunds(
            APIErrorPayload(code: "VALIDATION_ERROR", message: "Bad amount", httpStatus: 422)
        ))
        XCTAssertFalse(WalletTopUpPolicy.isInsufficientFunds(
            URLError(.notConnectedToInternet)
        ))
    }

    func testAirtimeAndBillQuotesAreMeasuredByTheirWalletTotal() throws {
        let quote = try JSONDecoder().decode(ProviderQuoteDTO.self, from: Data("""
        {
          "id": "quote-1",
          "product_id": "product-1",
          "provider_code": "RUKAPAY",
          "service_type": "airtime",
          "account_display": "0700 000 000",
          "amount": "5000",
          "fee": "300",
          "total": "5300",
          "currency": {"code": "UGX", "scale": "0"},
          "expires_at": "2026-08-25T12:00:00Z"
        }
        """.utf8))

        // A balance that clears the airtime but not its transaction fee is refused just the same,
        // so the total is what the screen has to measure against.
        let balance = wallet(available: "5100", scale: "0")
        XCTAssertNil(WalletTopUpPolicy.requirement(wallet: balance, debitAPIAmount: quote.amount))
        let requirement = try XCTUnwrap(
            WalletTopUpPolicy.requirement(wallet: balance, debitAPIAmount: quote.total)
        )
        XCTAssertEqual(requirement.shortfallAPIAmount, "200")
        XCTAssertEqual(requirement.suggestedTopUpAPIAmount, "200")
        XCTAssertEqual(requirement.walletID, balance.id)

        // And once that top-up lands, the same quote is approvable without a second round.
        XCTAssertTrue(requirement.isCovered(by: wallet(available: "5300", scale: "0")))
    }
}
