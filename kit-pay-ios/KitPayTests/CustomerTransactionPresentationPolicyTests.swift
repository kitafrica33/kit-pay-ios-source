import XCTest
@testable import KitPay

final class CustomerTransactionPresentationPolicyTests: XCTestCase {
    func testAllowlistExactlyMatchesBackendCustomerHistoryContract() {
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.supportedTypes,
            Set([
                "airtime", "bank_deposit", "bank_reversal", "bank_transfer",
                "bank_withdrawal", "bill_payment", "internal_transfer",
                "internal_transfer_reversal", "merchant_escrow_release", "merchant_payment",
                "merchant_refund", "provider_reversal", "referral_reward",
                "referral_reward_reversal",
            ])
        )
    }

    func testEveryExplicitCustomerTypeSurvivesCaseAndWhitespaceNormalization() {
        let transactions = CustomerTransactionPresentationPolicy.supportedTypes
            .sorted()
            .enumerated()
            .map { index, type in
                transaction(
                    id: "customer-\(index)",
                    type: " \n\(type.uppercased())\t"
                )
            }

        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(transactions)
                .map(\.id),
            transactions.map(\.id)
        )
    }

    func testInternalAndUnknownTypesFailClosedWithoutChangingCustomerOrder() {
        let transactions = [
            transaction(id: "customer-1", type: "internal_transfer"),
            transaction(id: "internal-commission", type: "institutional_commission"),
            transaction(id: "internal-revenue", type: "fee_revenue"),
            transaction(id: "internal-provider-funding", type: "operator_provider_fee_funding"),
            transaction(id: "customer-2", type: "bank_deposit"),
            transaction(id: "internal-settlement", type: "settlement_adjustment"),
            transaction(id: "future-unknown", type: "future_customer_movement"),
            transaction(id: "customer-3", type: "airtime"),
        ]

        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(transactions)
                .map(\.id),
            ["customer-1", "customer-2", "customer-3"]
        )

        var cachedTransactions = transactions
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.hardenCustomerTransactions(
                from: &cachedTransactions
            ),
            5
        )
        XCTAssertEqual(cachedTransactions.map(\.id), ["customer-1", "customer-2", "customer-3"])
    }

    func testModernTotalsRequireOnePositiveSideMatchingDirection() {
        let validCredit = transaction(
            id: "valid-credit",
            direction: " CREDIT ",
            amount: "150000.00",
            totals: CustomerTransactionTotals(added: "150000.00", deducted: "0")
        )
        let validDebit = transaction(
            id: "valid-debit",
            direction: "debit",
            amount: "25000",
            totals: CustomerTransactionTotals(added: "0.00", deducted: "25000")
        )
        let invalid = [
            transaction(
                id: "credit-wrong-side",
                totals: CustomerTransactionTotals(added: "0", deducted: "100")
            ),
            transaction(
                id: "debit-wrong-side",
                direction: "debit",
                totals: CustomerTransactionTotals(added: "100", deducted: "0")
            ),
            transaction(
                id: "both-positive",
                totals: CustomerTransactionTotals(added: "100", deducted: "5")
            ),
            transaction(
                id: "both-zero",
                totals: CustomerTransactionTotals(added: "0", deducted: "0")
            ),
            transaction(
                id: "public-amount-mismatch",
                amount: "101",
                totals: CustomerTransactionTotals(added: "100", deducted: "0")
            ),
            transaction(
                id: "negative",
                totals: CustomerTransactionTotals(added: "-100", deducted: "0")
            ),
            transaction(
                id: "grouped-number",
                totals: CustomerTransactionTotals(added: "1,000", deducted: "0")
            ),
            transaction(
                id: "malformed",
                totals: CustomerTransactionTotals(added: "100UGX", deducted: "0")
            ),
            transaction(
                id: "unknown-direction",
                direction: "incoming",
                totals: CustomerTransactionTotals(added: "100", deducted: "0")
            ),
        ]

        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(
                [validCredit] + invalid + [validDebit]
            ).map(\.id),
            ["valid-credit", "valid-debit"]
        )
    }

    func testLegacyRowsWithoutCombinedTotalsFailClosed() {
        var rows = [
            transaction(id: "credit", direction: "credit", amount: "100.50", totals: nil),
            transaction(id: "debit", direction: " DEBIT ", amount: "75", totals: nil),
        ]

        XCTAssertTrue(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(rows).isEmpty
        )
        XCTAssertEqual(rows[0].customerImpactAmount, "0")
        XCTAssertEqual(rows[1].customerImpactAmount, "0")
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.hardenCustomerTransactions(
                from: &rows
            ),
            2
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testActivitySummaryCombinesAuthoritativeCustomerTotals() {
        let wallet = wallet()
        let transactions = [
            transaction(
                id: "credit-one",
                amount: "150000.00",
                totals: CustomerTransactionTotals(added: "150000.00", deducted: "0")
            ),
            transaction(
                id: "credit-two",
                amount: "0.25",
                totals: CustomerTransactionTotals(added: "0.25", deducted: "0")
            ),
            transaction(
                id: "debit",
                direction: "debit",
                amount: "25000.5",
                totals: CustomerTransactionTotals(added: "0", deducted: "25000.5")
            ),
            transaction(
                id: "private-leg",
                type: "institutional_commission",
                amount: "900",
                totals: CustomerTransactionTotals(added: "900", deducted: "0")
            ),
        ]

        let summary = CustomerTransactionPresentationPolicy.activitySummary(
            transactions,
            for: wallet
        )

        XCTAssertEqual(summary.addedMinorUnits, 15_000_025)
        XCTAssertEqual(summary.deductedMinorUnits, 2_500_050)
        XCTAssertEqual(
            KitMoney.formatted(
                minorUnits: summary.addedMinorUnits,
                code: wallet.currency.code,
                scale: wallet.currency.decimalScale
            ),
            "UGX 150,000.25"
        )
        XCTAssertEqual(
            KitMoney.formatted(
                minorUnits: summary.deductedMinorUnits,
                code: wallet.currency.code,
                scale: wallet.currency.decimalScale
            ),
            "UGX 25,000.5"
        )
    }

    func testSelectedWalletHistoryAndSummaryExcludeOtherWalletsAndCurrencies() {
        let selectedWallet = wallet()
        let rows = [
            transaction(id: "selected"),
            transaction(id: "other-wallet", walletId: "wallet-2"),
            transaction(
                id: "other-currency",
                currency: CurrencyDTO(code: "USD", scale: "2")
            ),
            transaction(
                id: "other-scale",
                currency: CurrencyDTO(code: "UGX", scale: "0")
            ),
        ]

        let visible = CustomerTransactionPresentationPolicy.customerVisibleTransactions(
            rows,
            for: selectedWallet
        )
        let summary = CustomerTransactionPresentationPolicy.activitySummary(
            rows,
            for: selectedWallet
        )

        XCTAssertEqual(visible.map(\.id), ["selected"])
        XCTAssertEqual(summary.addedMinorUnits, 10_000)
        XCTAssertEqual(summary.deductedMinorUnits, 0)
    }

    func testAmountsThatCannotBeRepresentedExactlyInMinorUnitsFailClosed() {
        let rows = [
            transaction(
                id: "over-precision",
                amount: "1.001",
                totals: CustomerTransactionTotals(added: "1.001", deducted: "0")
            ),
            transaction(
                id: "over-int64",
                amount: "92233720368547758.08",
                totals: CustomerTransactionTotals(
                    added: "92233720368547758.08",
                    deducted: "0"
                )
            ),
            transaction(
                id: "invalid-scale",
                currency: CurrencyDTO(code: "UGX", scale: "invalid")
            ),
        ]

        XCTAssertTrue(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(rows).isEmpty
        )
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.activitySummary(rows, for: wallet()),
            .zero
        )
    }

    func testActivitySummarySaturatesInsteadOfOverflowing() {
        let rows = [
            transaction(
                id: "maximum",
                amount: "92233720368547758.07",
                totals: CustomerTransactionTotals(
                    added: "92233720368547758.07",
                    deducted: "0"
                )
            ),
            transaction(
                id: "one-more-minor-unit",
                amount: "0.01",
                totals: CustomerTransactionTotals(added: "0.01", deducted: "0")
            ),
        ]

        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.activitySummary(rows, for: wallet())
                .addedMinorUnits,
            Int64.max
        )
    }

    func testLegacyAliasesFailClosedEvenWhenTheyCarryPlausibleTotals() {
        let aliases = [
            "airtime_purchase", "deposit", "mobile_money", "mobile_money_collection",
            "mobile_money_payout", "mobile_money_refund", "transfer", "transfer_reversal",
            "withdrawal",
        ]

        XCTAssertTrue(
            CustomerTransactionPresentationPolicy.customerVisibleTransactions(
                aliases.enumerated().map { index, type in
                    transaction(id: "legacy-\(index)", type: type)
                }
            ).isEmpty
        )
    }

    func testServiceBackedTypesSuppressStaleInstitutionalCounterpartiesAndReceipts() throws {
        let serviceTypes = CustomerTransactionPresentationPolicy.supportedTypes.subtracting(
            CustomerTransactionPresentationPolicy.customerCounterpartyTypes
        )

        for type in serviceTypes {
            let row = transaction(
                id: "service-\(type)",
                type: type,
                counterparty: Counterparty(
                    id: "institution-id",
                    name: "Kit Institutional Commission Wallet",
                    phone: "+256700000000",
                    accountNumber: "KIT-INTERNAL-COMMISSION"
                )
            )

            XCTAssertTrue(CustomerTransactionPresentationPolicy.isCustomerVisible(row), type)
            XCTAssertNil(row.customerCounterparty, type)

            let receipt = try XCTUnwrap(
                KitReceiptContent.from(transaction: row, senderName: "Kit Customer"),
                type
            )
            let renderedText = ([receipt.directionLine, receipt.shareMessage]
                + receipt.rows.flatMap { [$0.label, $0.value] })
                .joined(separator: " ")
                .lowercased()
            XCTAssertFalse(renderedText.contains("institution"), type)
            XCTAssertFalse(renderedText.contains("commission"), type)
            XCTAssertFalse(renderedText.contains("kit-internal"), type)
        }

        var cachedRows = serviceTypes.sorted().enumerated().map { index, type in
            transaction(
                id: "cached-service-\(index)",
                type: type,
                counterparty: Counterparty(
                    id: "institution-id",
                    name: "Kit Institutional Commission Wallet",
                    phone: "+256700000000",
                    accountNumber: "KIT-INTERNAL-COMMISSION"
                )
            )
        }
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.hardenCustomerTransactions(
                from: &cachedRows
            ),
            serviceTypes.count
        )
        XCTAssertTrue(cachedRows.allSatisfy { $0.counterparty == nil })
    }

    func testDirectTransferKeepsItsCustomerCounterparty() throws {
        let row = transaction(
            id: "direct-transfer",
            type: "internal_transfer",
            counterparty: Counterparty(
                id: "recipient-id",
                name: "Namisi Emmanuel",
                phone: "+256700000001",
                accountNumber: "KIT-CUSTOMER"
            )
        )

        XCTAssertEqual(row.customerCounterparty?.id, "recipient-id")
        XCTAssertEqual(row.customerCounterparty?.name, "Namisi Emmanuel")

        let receipt = try XCTUnwrap(
            KitReceiptContent.from(transaction: row, senderName: "Kit Customer")
        )
        XCTAssertEqual(receipt.directionLine, "Received from Namisi Emmanuel")
        XCTAssertEqual(
            receipt.rows.first(where: { $0.label == "From" })?.value,
            "Namisi Emmanuel"
        )

        var cachedRows = [row]
        XCTAssertEqual(
            CustomerTransactionPresentationPolicy.hardenCustomerTransactions(
                from: &cachedRows
            ),
            0
        )
        XCTAssertEqual(cachedRows.first?.counterparty, row.counterparty)
    }

    private func transaction(
        id: String,
        type: String = "internal_transfer",
        direction: String = "credit",
        amount: String = "100",
        totals: CustomerTransactionTotals? = CustomerTransactionTotals(
            added: "100",
            deducted: "0"
        ),
        walletId: String = "wallet-1",
        currency: CurrencyDTO = CurrencyDTO(code: "UGX", scale: "2"),
        counterparty: Counterparty? = nil
    ) -> WalletTransaction {
        WalletTransaction(
            id: id,
            walletId: walletId,
            reference: "REF-\(id)",
            amount: amount,
            totals: totals,
            currency: currency,
            type: type,
            direction: direction,
            status: "completed",
            counterparty: counterparty,
            note: nil,
            occurredAt: "2026-09-01T12:00:00Z"
        )
    }

    private func wallet() -> Wallet {
        Wallet(
            id: "wallet-1",
            name: "Primary wallet",
            accountNumber: "KIT-1000",
            accountType: "personal",
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            balances: WalletBalances(available: "0", ledger: "0"),
            status: "active",
            isPrimary: true
        )
    }
}
