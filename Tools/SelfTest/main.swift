import Foundation
import CryptoKit

// macOS-only check run in CI before the iOS build: the legacy CommonCrypto/Security crypto in Shared/Crypto.swift must be
// byte-compatible with CryptoKit (which the main Lumen app, and therefore the hosts, are compatible with).
// Compiled together with Shared/Crypto.swift:  swiftc -O Shared/Crypto.swift Tools/SelfTest/main.swift -o selftest

var failures = [String]()
func check(_ ok: Bool, _ what: String) { if !ok { failures.append(what); print("FAIL: \(what)") } }

if let e = CryptoSelfTest.run() { check(false, "known answer tests: \(e)") }

// AES-GCM vs CryptoKit, random sizes with the exact Lumen layout (nonce = 4 zero bytes || seq, AAD = 10 byte header).
for i in 0..<400 {
    let key = PairingCrypto.random(32)
    let seq = UInt64(i * 7919 + 1)
    var nonce = Data(count: 4)
    for k in 0..<8 { nonce.append(UInt8(truncatingIfNeeded: seq >> UInt64(56 - 8 * k))) }
    let aad = Data([0x4C, 0x45]) + nonce.suffix(8)
    let plain = PairingCrypto.random((i * 37) % 1300)

    let box = try! AES.GCM.seal(plain, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
    guard let mine = AESGCM(key: [UInt8](key)),
          let r = mine.seal(nonce: [UInt8](nonce), aad: [UInt8](aad), plaintext: [UInt8](plain)) else { check(false, "seal \(i)"); continue }
    check(Data(r.ciphertext) == box.ciphertext, "ciphertext \(i)")
    check(Data(r.tag) == box.tag, "tag \(i)")
    let back = mine.open(nonce: [UInt8](nonce), aad: [UInt8](aad), ciphertext: [UInt8](box.ciphertext), tag: [UInt8](box.tag))
    check(back.map { Data($0) } == plain, "open CryptoKit box \(i)")
}

// HKDF vs CryptoKit
for i in 0..<50 {
    let ikm = PairingCrypto.random(64), salt = PairingCrypto.random(32), info = Data("lumen-v1 c2s".utf8)
    let ck = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: 32)
    let mine = LegacyHash.hkdf(ikm: [UInt8](ikm), salt: [UInt8](salt), info: [UInt8](info), length: 32)
    check(ck.withUnsafeBytes { Data($0) } == Data(mine), "hkdf \(i)")
}

// ECDH: legacy SecKey key vs CryptoKit key, both directions, x9.63 public keys.
for i in 0..<20 {
    guard let a = P256Agreement() else { check(false, "key gen"); continue }
    let b = P256.KeyAgreement.PrivateKey()
    let peer = try! P256.KeyAgreement.PublicKey(x963Representation: a.publicKeyX963)
    let s1 = try! b.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
    let s2 = a.sharedSecret(peerX963: b.publicKey.x963Representation)
    check(s1 == s2, "ecdh \(i)")
}

// Pairing code / secret / key id are pure functions: print a fixed vector so it can be compared with the C# host if needed.
let pkC = Data((0..<65).map { UInt8($0) }), pkH = Data((0..<65).map { UInt8(100 + $0) })
let nC = Data((0..<16).map { UInt8(200 + $0) }), nH = Data((0..<16).map { UInt8(50 + $0) })
let digest = SHA256.hash(data: Data("lumen-sas-v1".utf8) + pkC + pkH + nC + nH)
let v = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
check(PairingCrypto.code(pkC: pkC, pkH: pkH, nonceC: nC, nonceH: nH) == String(format: "%05d", v % 100000), "sas code")

if failures.isEmpty { print("Legacy crypto matches CryptoKit: OK"); exit(0) } else { print("\(failures.count) failure(s)"); exit(1) }
