import XCTest
@testable import KitPay

final class MerchantAccountOnboardingTests: XCTestCase {
    func testMerchantHelpUsesOnlyItsCanonicalKitHostedURL() throws {
        let canonical = KitMerchantHelpURLPolicy.canonicalURL

        XCTAssertEqual(
            canonical.absoluteString,
            "https://pay.kit.africa/merchant-help"
        )
        XCTAssertTrue(KitMerchantHelpURLPolicy.isTrustedMerchantHelpURL(canonical))

        let rejectedValues = [
            "http://pay.kit.africa/merchant-help",
            "https://pay.kit.africa.evil.test/merchant-help",
            "https://user@pay.kit.africa/merchant-help",
            "https://user:password@pay.kit.africa/merchant-help",
            "https://pay.kit.africa:443/merchant-help",
            "https://pay.kit.africa/merchant-help/",
            "https://pay.kit.africa/%6derchant-help",
            "https://pay.kit.africa/merchant-help?next=other",
            "https://pay.kit.africa/merchant-help#other",
        ]

        for value in rejectedValues {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(
                KitMerchantHelpURLPolicy.isTrustedMerchantHelpURL(url),
                "Expected merchant help to reject \(value)"
            )
        }
    }

    func testOffersOnlyActiveBusinessWallets() {
        let personal = wallet(
            id: "personal-wallet",
            accountType: "personal",
            status: "active"
        )
        let inactiveBusiness = wallet(
            id: "inactive-business-wallet",
            accountType: "business",
            status: "suspended"
        )
        let activeBusiness = wallet(
            id: "active-business-wallet",
            accountType: " BUSINESS ",
            status: " ACTIVE "
        )

        XCTAssertEqual(
            MerchantAccountOnboardingPolicy.businessWallets(
                in: [personal, inactiveBusiness, activeBusiness]
            ).map(\.id),
            [activeBusiness.id]
        )
        XCTAssertNil(MerchantAccountOnboardingPolicy.selectedBusinessWallet(
            id: personal.id,
            from: [personal, activeBusiness]
        ))
        XCTAssertEqual(
            MerchantAccountOnboardingPolicy.selectedBusinessWallet(
                id: activeBusiness.id,
                from: [personal, activeBusiness]
            )?.id,
            activeBusiness.id
        )
    }

    func testRequiresExplicitChoiceWhenSeveralBusinessWalletsExist() {
        let first = wallet(
            id: "first-business-wallet",
            accountType: "business",
            status: "active"
        )
        let second = wallet(
            id: "second-business-wallet",
            accountType: "business",
            status: "active"
        )
        let personal = wallet(
            id: "personal-wallet",
            accountType: "personal",
            status: "active"
        )

        XCTAssertEqual(
            MerchantAccountOnboardingPolicy.initialBusinessWalletID(
                in: [personal, first],
                preferredWalletID: personal.id
            ),
            first.id
        )
        XCTAssertEqual(
            MerchantAccountOnboardingPolicy.initialBusinessWalletID(
                in: [personal, first, second],
                preferredWalletID: personal.id
            ),
            ""
        )
        XCTAssertEqual(
            MerchantAccountOnboardingPolicy.initialBusinessWalletID(
                in: [personal, first, second],
                preferredWalletID: second.id
            ),
            second.id
        )
    }

    func testAccountsStayScopedToTheSelectedSettlementWallet() {
        let selected = wallet(
            id: "selected-business-wallet",
            accountType: "business",
            status: "active"
        )
        let selectedAccount = account(
            id: "selected-merchant",
            settlementWalletID: selected.id
        )
        let otherAccount = account(
            id: "other-merchant",
            settlementWalletID: "other-business-wallet"
        )

        XCTAssertEqual(
            MerchantAccountOnboardingPolicy.merchantAccounts(
                [otherAccount, selectedAccount],
                linkedTo: selected
            ).map(\.id),
            [selectedAccount.id]
        )
        XCTAssertTrue(MerchantAccountOnboardingPolicy.merchantAccounts(
            [selectedAccount],
            linkedTo: nil
        ).isEmpty)
    }

    private func wallet(
        id: String,
        accountType: String,
        status: String
    ) -> Wallet {
        Wallet(
            id: id,
            name: id,
            accountNumber: nil,
            accountType: accountType,
            currency: CurrencyDTO(code: "UGX", scale: "2"),
            balances: WalletBalances(available: "0.00", ledger: "0.00"),
            status: status,
            isPrimary: false
        )
    }

    private func account(
        id: String,
        settlementWalletID: String
    ) -> MerchantAccountDTO {
        MerchantAccountDTO(
            id: id,
            publicId: "public-\(id)",
            displayName: id,
            legalName: nil,
            countryCode: "UG",
            settlementWalletId: settlementWalletID,
            status: "active",
            createdAt: "2026-08-21T00:00:00Z"
        )
    }
}
