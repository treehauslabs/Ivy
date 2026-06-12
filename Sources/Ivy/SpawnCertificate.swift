import Foundation
import Crypto
import Tally

/// A parent process's attestation that it spawned a child process: a signature
/// by the parent (issuer) over the child's public key and the chain-path scope
/// the child was spawned to serve. Certificates compose along the process tree
/// into a chain rooted at the top process's key, so a grandchild can prove
/// spawn-tree membership to any ancestor (`SpawnCertificateChain.verify`).
///
/// Trust follows provenance: a connection backed by a valid chain to a key the
/// verifier trusts as its tree root classifies as trusted; everything else is
/// federated. Revocation is simply dropping the cert — the link degrades to
/// federated. (This pass ships the primitive only; handshake wiring is separate.)
///
/// ## Canonical signing payload
/// The signature covers a deterministic, length-prefixed encoding — never JSON —
/// so there is no field-boundary ambiguity (`["Nexus","AB"]` and
/// `["Nexus","A","B"]` encode differently):
///
///     lp(domain) || lp(canonical child key) || lp(canonical issuer key)
///     || count(chainPath) || lp(element)…
///
/// where `lp` is the UInt16-big-endian length prefix used by Ivy's wire format,
/// `count` is a UInt16 element count, and keys are canonicalized to raw hex
/// (`ed01` Multikey prefix stripped) so both spellings of a key sign and verify
/// identically. Keys/signatures are the same Curve25519 (Ed25519) scheme Ivy
/// peers already use for identity.
public struct SpawnCertificate: Codable, Sendable, Equatable {
    public let childPublicKey: String
    public let chainPath: [String]
    public let issuerPublicKey: String
    public let signature: Data

    /// Spawn certificates and identify signatures must never be mutually
    /// replayable, hence a dedicated domain tag.
    private static let domain = "ivy.spawnCert.v1"
    /// Process trees are shallow; bound the scope depth defensively.
    public static let maxChainPathDepth = 255

    public init(childPublicKey: String, chainPath: [String], issuerPublicKey: String, signature: Data) {
        self.childPublicKey = childPublicKey
        self.chainPath = chainPath
        self.issuerPublicKey = issuerPublicKey
        self.signature = signature
    }

    /// Canonical payload the issuer signs. Returns empty Data when any field
    /// exceeds wire limits — callers must treat empty material as invalid
    /// (never sign or verify it), or distinct oversized certs would collide.
    public static func signingMaterial(childPublicKey: String, chainPath: [String], issuerPublicKey: String) -> Data {
        var data = Data()
        guard data.appendLengthPrefixedString(domain),
              data.appendLengthPrefixedString(Ivy.canonicalKeyHex(childPublicKey)),
              data.appendLengthPrefixedString(Ivy.canonicalKeyHex(issuerPublicKey)),
              data.appendCount(chainPath.count, max: UInt16(maxChainPathDepth)) else { return Data() }
        for element in chainPath {
            guard data.appendLengthPrefixedString(element) else { return Data() }
        }
        return data
    }

    /// Sign a spawn certificate for a child key. `issuerKeyPair` is the
    /// (publicKey: raw-hex, privateKey: raw bytes) shape `Ivy.generateKey`
    /// returns. Returns nil for a malformed key or oversized fields.
    public static func issue(
        childPublicKey: String,
        chainPath: [String],
        issuerKeyPair: (publicKey: String, privateKey: Data)
    ) -> SpawnCertificate? {
        guard issuerKeyPair.privateKey.count == 32,
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: issuerKeyPair.privateKey) else {
            return nil
        }
        let material = signingMaterial(
            childPublicKey: childPublicKey, chainPath: chainPath, issuerPublicKey: issuerKeyPair.publicKey)
        guard !material.isEmpty, let signature = try? privateKey.signature(for: material) else { return nil }
        return SpawnCertificate(
            childPublicKey: childPublicKey,
            chainPath: chainPath,
            issuerPublicKey: issuerKeyPair.publicKey,
            signature: signature)
    }

    /// True when `signature` verifies under the claimed issuer key over the
    /// canonical payload. Does NOT judge chain composition or scope nesting —
    /// that is `SpawnCertificateChain.verify`.
    public func hasValidSignature() -> Bool {
        guard !signature.isEmpty,
              let issuerBytes = Data(hexString: Ivy.canonicalKeyHex(issuerPublicKey)), issuerBytes.count == 32,
              let verifyKey = try? Curve25519.Signing.PublicKey(rawRepresentation: issuerBytes) else {
            return false
        }
        let material = Self.signingMaterial(
            childPublicKey: childPublicKey, chainPath: chainPath, issuerPublicKey: issuerPublicKey)
        guard !material.isEmpty else { return false }
        return verifyKey.isValidSignature(signature, for: material)
    }
}

public enum SpawnCertificateChain {
    /// Verify that `leaf` is a member of the spawn tree rooted at
    /// `trustedRoot`, proven by `chain` ordered root-first. All keys compare in
    /// canonical raw-hex form. Returns true only when:
    /// - every certificate's signature is valid over the canonical payload;
    /// - the chain composes: cert[i].childPublicKey == cert[i+1].issuerPublicKey;
    /// - chain[0] is issued by `trustedRoot`;
    /// - the last certificate's child is `leaf`;
    /// - scopes nest: each cert's chainPath is a STRICT prefix of the next
    ///   cert's (parents spawn children deeper in the tree, never sideways or
    ///   up), and no chainPath is empty (an empty scope would strict-prefix
    ///   everything);
    /// - no link is self-signed (issuer == child) — only the verifier's own
    ///   `trustedRoot` choice confers root authority, never a self-claim.
    ///
    /// Root semantics: the root process needs no certificate for itself — an
    /// empty chain verifies exactly when `leaf` IS `trustedRoot`.
    public static func verify(chain: [SpawnCertificate], leaf: PeerID, trustedRoot: String) -> Bool {
        let rootKey = Ivy.canonicalKeyHex(trustedRoot)
        let leafKey = Ivy.canonicalKeyHex(leaf.publicKey)
        guard !chain.isEmpty else { return leafKey == rootKey }

        guard Ivy.canonicalKeyHex(chain[0].issuerPublicKey) == rootKey,
              Ivy.canonicalKeyHex(chain[chain.count - 1].childPublicKey) == leafKey else { return false }

        for (index, cert) in chain.enumerated() {
            guard !cert.chainPath.isEmpty,
                  Ivy.canonicalKeyHex(cert.issuerPublicKey) != Ivy.canonicalKeyHex(cert.childPublicKey),
                  cert.hasValidSignature() else { return false }
            if index + 1 < chain.count {
                let next = chain[index + 1]
                guard Ivy.canonicalKeyHex(cert.childPublicKey) == Ivy.canonicalKeyHex(next.issuerPublicKey),
                      isStrictPrefix(cert.chainPath, of: next.chainPath) else { return false }
            }
        }
        return true
    }

    private static func isStrictPrefix(_ prefix: [String], of path: [String]) -> Bool {
        prefix.count < path.count && Array(path.prefix(prefix.count)) == prefix
    }
}
