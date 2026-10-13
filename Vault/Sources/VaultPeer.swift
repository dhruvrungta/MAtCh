// Written by tools/build_vault.sh. Do not edit by hand.

enum VaultPeer {
    /// Who may talk to the vault: Match itself, signed with the project's certificate.
    static let requirement =
        "identifier \"com.dhruvrungta.match\" and certificate leaf = H\"dde768b14ddc7ae603677e2ef7e3339845d0af68\""
}
