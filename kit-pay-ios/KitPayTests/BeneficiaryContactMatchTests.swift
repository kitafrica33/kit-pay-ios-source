import XCTest
@testable import KitPay

final class BeneficiaryContactMatchTests: XCTestCase {
    func testBankBeneficiaryShowsThePhotoOfTheKitPayContactWithThatName() {
        let index = BeneficiaryContactIndex(
            contacts: [
                contact(
                    id: "00000000-0000-0000-0000-0000000000a1",
                    name: "John Mukasa",
                    phone: "+256759948200",
                    avatar: "https://cdn.example/john.jpg"
                ),
                contact(
                    id: "00000000-0000-0000-0000-0000000000a2",
                    name: "Sarah Nakato",
                    phone: "+256772000111"
                )
            ]
        )

        // The bank prints the surname first and in capitals.
        let matched = index.contact(forAccountName: "MUKASA JOHN")

        XCTAssertEqual(matched?.avatarURL, "https://cdn.example/john.jpg")
    }

    func testAMiddleNameOnOneSideIsStillTheSamePerson() {
        let index = BeneficiaryContactIndex(
            contacts: [
                contact(
                    id: "00000000-0000-0000-0000-0000000000b1",
                    name: "John Mukasa",
                    phone: "+256759948200",
                    avatar: "https://cdn.example/john.jpg"
                )
            ]
        )

        XCTAssertEqual(
            index.contact(forAccountName: "John Peter Mukasa")?.avatarURL,
            "https://cdn.example/john.jpg"
        )
    }

    func testTwoContactsWithTheSameNameShowNoPhotoAtAll() {
        let index = BeneficiaryContactIndex(
            contacts: [
                contact(
                    id: "00000000-0000-0000-0000-0000000000c1",
                    name: "John Mukasa",
                    phone: "+256759948200",
                    avatar: "https://cdn.example/one.jpg"
                ),
                contact(
                    id: "00000000-0000-0000-0000-0000000000c2",
                    name: "John Mukasa",
                    phone: "+256772000111",
                    avatar: "https://cdn.example/two.jpg"
                )
            ]
        )

        XCTAssertNil(
            index.contact(forAccountName: "John Mukasa"),
            "A face above an account number has to be the right face or no face."
        )
    }

    func testTheSameKitPayAccountSavedOnTwoContactCardsIsStillOneFace() {
        let index = BeneficiaryContactIndex(
            contacts: [
                contact(
                    id: "00000000-0000-0000-0000-0000000000d1",
                    name: "John Mukasa",
                    phone: "+256759948200",
                    avatar: "https://cdn.example/john.jpg"
                ),
                contact(
                    id: "00000000-0000-0000-0000-0000000000d1",
                    name: "John Mukasa",
                    phone: "0759948200",
                    avatar: "https://cdn.example/john.jpg"
                )
            ]
        )

        XCTAssertEqual(
            index.contact(forAccountName: "John Mukasa")?.avatarURL,
            "https://cdn.example/john.jpg"
        )
    }

    func testASingleWordAccountNameIsNeverEvidence() {
        let index = BeneficiaryContactIndex(
            contacts: [
                contact(
                    id: "00000000-0000-0000-0000-0000000000e1",
                    name: "Mum",
                    phone: "+256759948200",
                    avatar: "https://cdn.example/mum.jpg"
                )
            ]
        )

        XCTAssertNil(index.contact(forAccountName: "Mum"))
    }

    func testAContactWhoIsNotOnKitPayNeverLendsAPhoto() {
        let index = BeneficiaryContactIndex(
            contacts: [
                contact(
                    id: "00000000-0000-0000-0000-0000000000f1",
                    name: "John Mukasa",
                    phone: "+256759948200",
                    avatar: "https://cdn.example/john.jpg",
                    isKitUser: false
                )
            ]
        )

        XCTAssertNil(index.contact(forAccountName: "John Mukasa"))
        XCTAssertNil(
            index.contact(forMaskedPhone: "••••••••8200", accountName: "John Mukasa")
        )
        XCTAssertTrue(index.isEmpty)
    }

    // MARK: - Mobile money

    func testMobileMoneyAccountMatchesOnTheDigitsTheMaskLeavesVisible() {
        let index = BeneficiaryContactIndex(
            contacts: [
                contact(
                    id: "00000000-0000-0000-0000-000000000101",
                    name: "John Mukasa",
                    phone: "0759948200",
                    avatar: "https://cdn.example/john.jpg"
                ),
                contact(
                    id: "00000000-0000-0000-0000-000000000102",
                    name: "Sarah Nakato",
                    phone: "+256772000111"
                )
            ]
        )

        XCTAssertEqual(
            index.contact(forMaskedPhone: "••••••••8200", accountName: "MUKASA JOHN")?.avatarURL,
            "https://cdn.example/john.jpg"
        )
    }

    func testTwoNumbersSharingTheirVisibleDigitsAreSeparatedByName() {
        let index = BeneficiaryContactIndex(
            contacts: [
                contact(
                    id: "00000000-0000-0000-0000-000000000201",
                    name: "John Mukasa",
                    phone: "+256759948200",
                    avatar: "https://cdn.example/john.jpg"
                ),
                contact(
                    id: "00000000-0000-0000-0000-000000000202",
                    name: "Sarah Nakato",
                    phone: "+256772008200",
                    avatar: "https://cdn.example/sarah.jpg"
                )
            ]
        )

        XCTAssertEqual(
            index.contact(forMaskedPhone: "••••••••8200", accountName: "Sarah Nakato")?.avatarURL,
            "https://cdn.example/sarah.jpg"
        )
        XCTAssertNil(
            index.contact(forMaskedPhone: "••••••••8200", accountName: "Airtel line"),
            "Without a name that agrees, the shared digits are not enough."
        )
    }

    func testAMaskThatHidesEverythingMatchesNobody() {
        let index = BeneficiaryContactIndex(
            contacts: [
                contact(
                    id: "00000000-0000-0000-0000-000000000301",
                    name: "John Mukasa",
                    phone: "+256759948200",
                    avatar: "https://cdn.example/john.jpg"
                )
            ]
        )

        XCTAssertNil(index.contact(forMaskedPhone: "••••••••••••", accountName: "John Mukasa"))
        XCTAssertNil(
            index.contact(forMaskedPhone: "•••••••••00", accountName: "John Mukasa"),
            "Two visible digits match one person in a hundred."
        )
    }

    // MARK: - Name arithmetic

    func testInitialsAndTitlesAreNotTreatedAsNames() {
        XCTAssertEqual(BeneficiaryNameMatching.tokens("Mr. J K Mukasa"), ["mukasa"])
        XCTAssertEqual(
            BeneficiaryNameMatching.tokens("Nakato  Sarah"),
            ["nakato", "sarah"]
        )
    }

    func testVisibleSuffixReadsOnlyTheTrailingRunOfDigits() {
        XCTAssertEqual(
            BeneficiaryNameMatching.visibleSuffix(of: "••••••••8200", length: 3),
            "200"
        )
        XCTAssertNil(BeneficiaryNameMatching.visibleSuffix(of: "8200••••", length: 3))
    }

    // MARK: - Fixtures

    private func contact(
        id: String,
        name: String,
        phone: String,
        avatar: String? = nil,
        isKitUser: Bool = true
    ) -> WalletContactDTO {
        WalletContactDTO(
            id: id,
            contactId: nil,
            name: name,
            phone: phone,
            isKitUser: isKitUser,
            favorite: nil,
            status: nil,
            tag: nil,
            avatarURL: avatar,
            receivingWalletId: nil
        )
    }
}
