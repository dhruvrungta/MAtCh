import Foundation
import Testing
@testable import Match

@Suite struct VaultCredentialStoreTests {
    private let service = "com.dhruvrungta.match.vault.credentials.tests"
    private let saved = Credentials(userId: "25BIT0088", password: "pw")

    private func makeStore(
        vault: FakeVault = FakeVault(), legacy: InMemoryCredentialStore = InMemoryCredentialStore(nil)
    ) -> VaultCredentialStore {
        VaultCredentialStore(vault: vault, service: service, legacy: legacy)
    }

    // MARK: A fresh install

    @Test func savesToAndLoadsFromTheVaultWithNoApprovalEver() throws {
        let vault = FakeVault()
        let legacy = InMemoryCredentialStore(nil)
        let store = makeStore(vault: vault, legacy: legacy)

        #expect(try store.savedUserId() == nil)
        #expect(try store.load(allowPrompt: false) == .missing)
        #expect(try !store.approvalNeeded())

        try store.save(saved)
        #expect(vault.item(service) == saved)
        #expect(try legacy.savedUserId() == nil)
        #expect(try store.savedUserId() == "25BIT0088")
        #expect(try !store.approvalNeeded())
        // An automatic sign-in reads it without being allowed to ask the user anything.
        #expect(try store.load(allowPrompt: false) == .found(saved))
        #expect(legacy.promptCount == 0)

        try store.clear()
        #expect(vault.item(service) == nil)
        #expect(try store.load(allowPrompt: false) == .missing)
    }

    @Test func readingTheAccountNameNeverAsksTheVaultForTheSecret() throws {
        let vault = FakeVault()
        let store = makeStore(vault: vault)
        try store.save(saved)
        _ = try store.savedUserId()
        _ = try store.approvalNeeded()
        #expect(vault.loads == 0)
    }

    // MARK: Coming from a version before the vault

    @Test func anOlderSignInThatNeedsApprovalIsNotTouchedUnasked() throws {
        let vault = FakeVault()
        let legacy = InMemoryCredentialStore(saved, needsApproval: true)
        let store = makeStore(vault: vault, legacy: legacy)

        #expect(try store.savedUserId() == "25BIT0088")
        #expect(try store.approvalNeeded())
        #expect(try store.load(allowPrompt: false) == .needsApproval)
        #expect(legacy.promptCount == 0)
        #expect(vault.item(service) == nil)
    }

    @Test func oneApprovalMovesItIntoTheVaultForGood() throws {
        let vault = FakeVault()
        let legacy = InMemoryCredentialStore(saved, needsApproval: true)
        let store = makeStore(vault: vault, legacy: legacy)

        // The user clicks Unlock.
        #expect(try store.load(allowPrompt: true) == .found(saved))
        #expect(legacy.promptCount == 1)
        #expect(vault.item(service) == saved)
        #expect(try legacy.savedUserId() == nil)

        // From here on nothing needs approving, by this build or any later one.
        #expect(try !store.approvalNeeded())
        #expect(try store.load(allowPrompt: false) == .found(saved))
        #expect(legacy.promptCount == 1)

        let afterAnUpdate = makeStore(vault: vault, legacy: InMemoryCredentialStore(nil))
        #expect(try !afterAnUpdate.approvalNeeded())
        #expect(try afterAnUpdate.load(allowPrompt: false) == .found(saved))
    }

    @Test func anOlderSignInThisBuildCanAlreadyReadMovesSilently() throws {
        let vault = FakeVault()
        let legacy = InMemoryCredentialStore(saved)
        let store = makeStore(vault: vault, legacy: legacy)

        #expect(try !store.approvalNeeded())
        #expect(try store.load(allowPrompt: false) == .found(saved))
        #expect(vault.item(service) == saved)
        #expect(try legacy.savedUserId() == nil)
        #expect(legacy.promptCount == 0)
    }

    @Test func savingNewDetailsReplacesAnOlderSignIn() throws {
        let vault = FakeVault()
        let legacy = InMemoryCredentialStore(saved)
        let store = makeStore(vault: vault, legacy: legacy)
        let newer = Credentials(userId: "24BCE1234", password: "newer")

        try store.save(newer)
        #expect(vault.item(service) == newer)
        #expect(try legacy.savedUserId() == nil)
        #expect(try store.savedUserId() == "24BCE1234")
    }

    @Test func anOlderItemThatCannotBeDeletedDoesNotGetInTheWay() throws {
        // macOS will not let an unapproved build delete the older item.
        let vault = FakeVault()
        let legacy = InMemoryCredentialStore(saved, needsApproval: true)
        let store = makeStore(vault: vault, legacy: legacy)
        let newer = Credentials(userId: "24BCE1234", password: "newer")

        try store.save(newer)
        #expect(try legacy.savedUserId() == "25BIT0088")
        // The vault's copy is the one that counts.
        #expect(try store.savedUserId() == "24BCE1234")
        #expect(try !store.approvalNeeded())
        #expect(try store.load(allowPrompt: false) == .found(newer))

        // Removing everything says so when the older item is still stuck.
        #expect(throws: KeychainError.needsApproval) { try store.clear() }
        #expect(vault.item(service) == nil)
    }

    // MARK: A build the vault will not talk to

    @Test func withoutTheVaultEverythingGoesToTheKeychainAsBefore() throws {
        let vault = FakeVault(available: false)
        let legacy = InMemoryCredentialStore(nil)
        let store = makeStore(vault: vault, legacy: legacy)
        #expect(!store.usesVault)

        try store.save(saved)
        #expect(vault.item(service) == nil)
        #expect(try legacy.savedUserId() == "25BIT0088")
        #expect(try store.savedUserId() == "25BIT0088")
        #expect(try store.load(allowPrompt: false) == .found(saved))
        try store.clear()
        #expect(try store.load(allowPrompt: false) == .missing)
    }

    @Test func withoutTheVaultAnUnapprovedBuildStillNeedsUnlocking() throws {
        let store = makeStore(
            vault: FakeVault(available: false), legacy: InMemoryCredentialStore(saved, needsApproval: true)
        )
        #expect(try store.approvalNeeded())
        #expect(try store.load(allowPrompt: false) == .needsApproval)
        #expect(try store.load(allowPrompt: true) == .found(saved))
    }

    // MARK: Trouble

    @Test func aVaultThatStopsAnsweringIsReportedNotHidden() throws {
        let vault = FakeVault()
        let store = makeStore(vault: vault)
        try store.save(saved)
        vault.startFailing()

        #expect(throws: KeychainError.vaultUnavailable("gone")) { try store.load(allowPrompt: false) }
        #expect(throws: KeychainError.vaultUnavailable("gone")) { try store.save(saved) }
        #expect(throws: KeychainError.vaultUnavailable("gone")) { try store.savedUserId() }
    }

    @Test func theVaultOnlyAcceptsItsOwnKindOfItem() {
        #expect(VaultCredentialStore.defaultService.hasPrefix(VaultInfo.allowedServicePrefix))
        #expect((VaultCredentialStore.defaultService + ".mock").hasPrefix(VaultInfo.allowedServicePrefix))
        // The older item's name must not be something the vault would touch.
        #expect(!KeychainStore.defaultService.hasPrefix(VaultInfo.allowedServicePrefix))
    }
}
