import Foundation
import CommonCrypto
import Security

// Legacy (iOS 12+) port of the Lumen crypto layer. Wire format is byte-identical to the modern Shared/Crypto.swift
// (CryptoKit) and HostCommon/Crypto.cs, but built only from CommonCrypto + Security:
//   SHA-256 = CC_SHA256, HMAC = CCHmac, HKDF-SHA256 = RFC 5869 on top of it,
//   ECDH P-256 = SecKeyCreateRandomKey + SecKeyCopyKeyExchangeResult(.ecdhKeyExchangeStandard) (raw x coordinate),
//   AES-256-GCM = own implementation: CTR keystream from AES-ECB (CCCryptor) + GHASH (Shoup 4-bit tables).
//
// PAIRING (once per device; the 5-digit code is shown on the device and typed on the computer):
//   Packets use PacketType.pair, unencrypted; payload = [step u8] + body.
//     1 client -> host : [1][32 commit = SHA256(pkC || nonceC)][device name, UTF-8, up to 40 bytes]
//     2 host -> client : [2][65 host P-256 public key (x9.63)][16 host nonce]
//     3 client -> host : [3][65 client public key][16 client nonce]     (host checks the commit)
//     4 host -> client : [4][result: 0 paired, 1 wrong code, 2 busy / locked out, 3 error]
//   code = (u32 big endian of SHA256("lumen-sas-v1" || pkC || pkH || nonceC || nonceH)[0..<4]) % 100000
//   Long-term secret = HKDF-SHA256(ECDH raw shared secret, salt nonceC || nonceH, info "lumen-pair-v1") -> 32 bytes.
//   Key id = SHA256("lumen-keyid" || secret)[0..<8].
//
// CONNECTING (every session), handshake packets (PacketType.handshake, unencrypted):
//     client -> host : [0 role][2 version][65 P-256 public key][16 client nonce][8 key id]
//     host -> client : [1 role][2 version][65 public key][16 server nonce]       (key id known)
//                    : [2 role][2 version]                                       (key id unknown -> pairing required)
//   Keys: ikm = ECDH raw secret (32) || long-term secret (32);  salt = client nonce || server nonce;
//         c2s / s2c = HKDF-SHA256(ikm, salt, info "lumen-v1 c2s" / "lumen-v1 s2c") -> 32 bytes each.
//   Sealed packet: [0x4C 0x45][seq u64 BE][ciphertext][16-byte tag], AES-256-GCM,
//   nonce = 4 zero bytes || seq (8 bytes BE), AAD = the first 10 bytes. The plaintext is a normal Lumen packet.

// MARK: - Hashing

enum LegacyHash {
    static func sha256(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = input.withUnsafeBufferPointer { p in
            CC_SHA256(p.baseAddress, CC_LONG(input.count), &out)
        }
        return out
    }

    static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        key.withUnsafeBufferPointer { kp in
            data.withUnsafeBufferPointer { dp in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), kp.baseAddress, key.count, dp.baseAddress, data.count, &out)
            }
        }
        return out
    }

    /// RFC 5869 HKDF with SHA-256.
    static func hkdf(ikm: [UInt8], salt: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        let realSalt: [UInt8] = salt.isEmpty ? [UInt8](repeating: 0, count: 32) : salt
        let prk = hmacSHA256(key: realSalt, data: ikm)
        var okm = [UInt8]()
        var t = [UInt8]()
        var counter: UInt8 = 1
        while okm.count < length {
            var input = t
            input.append(contentsOf: info)
            input.append(counter)
            t = hmacSHA256(key: prk, data: input)
            okm.append(contentsOf: t)
            counter = counter &+ 1
        }
        return Array(okm.prefix(length))
    }
}

// MARK: - AES-256-GCM (own implementation)

/// AES-GCM with a 96-bit nonce and 16-byte tag. CommonCrypto has no public GCM, so the counter-mode keystream
/// is produced with AES-ECB (one CCCryptor call per packet) and the authentication tag with GHASH over GF(2^128)
/// using Shoup's 4-bit tables (about 30x faster than the bitwise method; important at 80 Mbps on old CPUs).
final class AESGCM {
    private static let remTable: [UInt64] = [
        0x0000, 0x1C20, 0x3840, 0x2460, 0x7080, 0x6CA0, 0x48C0, 0x54E0,
        0xE100, 0xFD20, 0xD940, 0xC560, 0x9180, 0x8DA0, 0xA9C0, 0xB5E0
    ]

    private var cryptor: CCCryptorRef?
    private var tableHi = [UInt64](repeating: 0, count: 16)
    private var tableLo = [UInt64](repeating: 0, count: 16)
    private let lock = NSLock()

    /// Key must be 32 bytes. Fails (nil) if CommonCrypto refuses the key.
    init?(key: [UInt8]) {
        guard key.count == 32 else { return nil }
        var ref: CCCryptorRef?
        let st = key.withUnsafeBufferPointer { kp in
            CCCryptorCreate(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            kp.baseAddress, key.count, nil, &ref)
        }
        guard st == CCCryptorStatus(kCCSuccess), let c = ref else { return nil }
        cryptor = c
        guard let h = ecb([UInt8](repeating: 0, count: 16)), h.count == 16 else { return nil }
        buildTable(h)
    }

    deinit {
        if let c = cryptor { CCCryptorRelease(c) }
    }

    /// AES-ECB encryption of whole blocks (data.count must be a multiple of 16).
    private func ecb(_ input: [UInt8]) -> [UInt8]? {
        guard let c = cryptor else { return nil }
        var out = [UInt8](repeating: 0, count: input.count + 16)
        let cap = out.count
        var moved = 0
        let st = input.withUnsafeBufferPointer { ip in
            CCCryptorUpdate(c, ip.baseAddress, input.count, &out, cap, &moved)
        }
        guard st == CCCryptorStatus(kCCSuccess), moved == input.count else { return nil }
        return Array(out.prefix(moved))
    }

    private static func reduce1Bit(_ hi: UInt64, _ lo: UInt64) -> (UInt64, UInt64) {
        let t: UInt64 = (lo & 1) != 0 ? 0xE100_0000_0000_0000 : 0
        return ((hi >> 1) ^ t, (hi << 63) | (lo >> 1))
    }

    private static func be64(_ b: [UInt8], _ off: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(b[off + i]) }
        return v
    }

    private func buildTable(_ h: [UInt8]) {
        let hi = AESGCM.be64(h, 0), lo = AESGCM.be64(h, 8)
        tableHi[8] = hi; tableLo[8] = lo
        var v = AESGCM.reduce1Bit(hi, lo)
        tableHi[4] = v.0; tableLo[4] = v.1
        v = AESGCM.reduce1Bit(v.0, v.1)
        tableHi[2] = v.0; tableLo[2] = v.1
        v = AESGCM.reduce1Bit(v.0, v.1)
        tableHi[1] = v.0; tableLo[1] = v.1
        var i = 2
        while i <= 8 {
            for j in 1..<i {
                tableHi[i + j] = tableHi[i] ^ tableHi[j]
                tableLo[i + j] = tableLo[i] ^ tableLo[j]
            }
            i *= 2
        }
    }

    /// x = (x * H) in GF(2^128), x is 16 bytes in wire order.
    private func gmult(_ x: inout [UInt8]) {
        var cnt = 15
        var nlo = Int(x[15] & 0x0F)
        var nhi = Int(x[15] >> 4)
        var zh = tableHi[nlo], zl = tableLo[nlo]
        while true {
            var rem = Int(zl & 0x0F)
            zl = (zh << 60) | (zl >> 4)
            zh = zh >> 4
            zh ^= AESGCM.remTable[rem] << 48
            zh ^= tableHi[nhi]; zl ^= tableLo[nhi]
            cnt -= 1
            if cnt < 0 { break }
            nlo = Int(x[cnt] & 0x0F)
            nhi = Int(x[cnt] >> 4)
            rem = Int(zl & 0x0F)
            zl = (zh << 60) | (zl >> 4)
            zh = zh >> 4
            zh ^= AESGCM.remTable[rem] << 48
            zh ^= tableHi[nlo]; zl ^= tableLo[nlo]
        }
        for i in 0..<8 {
            x[i] = UInt8(truncatingIfNeeded: zh >> UInt64(56 - 8 * i))
            x[8 + i] = UInt8(truncatingIfNeeded: zl >> UInt64(56 - 8 * i))
        }
    }

    private func ghashUpdate(_ x: inout [UInt8], _ data: [UInt8]) {
        var off = 0
        while off < data.count {
            let n = min(16, data.count - off)
            for i in 0..<n { x[i] ^= data[off + i] }
            gmult(&x)
            off += 16
        }
    }

    private func tag(aad: [UInt8], ciphertext: [UInt8], mask: [UInt8]) -> [UInt8] {
        var x = [UInt8](repeating: 0, count: 16)
        ghashUpdate(&x, aad)
        ghashUpdate(&x, ciphertext)
        var lens = [UInt8](repeating: 0, count: 16)
        let aBits = UInt64(aad.count) * 8, cBits = UInt64(ciphertext.count) * 8
        for i in 0..<8 {
            lens[i] = UInt8(truncatingIfNeeded: aBits >> UInt64(56 - 8 * i))
            lens[8 + i] = UInt8(truncatingIfNeeded: cBits >> UInt64(56 - 8 * i))
        }
        ghashUpdate(&x, lens)
        for i in 0..<16 { x[i] ^= mask[i] }
        return x
    }

    /// Keystream for the message: returns (E(K, J0) used to mask the tag, keystream of `length` bytes).
    private func keystream(nonce: [UInt8], length: Int) -> (mask: [UInt8], stream: [UInt8])? {
        let blocks = (length + 15) / 16
        var input = [UInt8]()
        input.reserveCapacity((blocks + 1) * 16)
        input.append(contentsOf: nonce)
        input.append(contentsOf: [0, 0, 0, 1])                  // J0
        var counter: UInt32 = 2
        for _ in 0..<blocks {
            input.append(contentsOf: nonce)
            input.append(UInt8(truncatingIfNeeded: counter >> 24)); input.append(UInt8(truncatingIfNeeded: counter >> 16))
            input.append(UInt8(truncatingIfNeeded: counter >> 8)); input.append(UInt8(truncatingIfNeeded: counter))
            counter = counter &+ 1
        }
        guard let out = ecb(input) else { return nil }
        return (Array(out[0..<16]), Array(out[16...]))
    }

    /// Returns ciphertext || 16-byte tag, or nil on bad parameters.
    func seal(nonce: [UInt8], aad: [UInt8], plaintext: [UInt8]) -> (ciphertext: [UInt8], tag: [UInt8])? {
        guard nonce.count == 12 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let ks = keystream(nonce: nonce, length: plaintext.count) else { return nil }
        var ct = [UInt8](repeating: 0, count: plaintext.count)
        for i in 0..<plaintext.count { ct[i] = plaintext[i] ^ ks.stream[i] }
        return (ct, tag(aad: aad, ciphertext: ct, mask: ks.mask))
    }

    /// Returns the plaintext, or nil if the tag does not verify.
    func open(nonce: [UInt8], aad: [UInt8], ciphertext: [UInt8], tag expected: [UInt8]) -> [UInt8]? {
        guard nonce.count == 12, expected.count == 16 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let ks = keystream(nonce: nonce, length: ciphertext.count) else { return nil }
        let computed = tag(aad: aad, ciphertext: ciphertext, mask: ks.mask)
        var diff: UInt8 = 0
        for i in 0..<16 { diff |= computed[i] ^ expected[i] }
        guard diff == 0 else { return nil }
        var pt = [UInt8](repeating: 0, count: ciphertext.count)
        for i in 0..<ciphertext.count { pt[i] = ciphertext[i] ^ ks.stream[i] }
        return pt
    }
}

// MARK: - ECDH P-256 (Security framework)

final class P256Agreement {
    private let privateKey: SecKey
    let publicKeyX963: Data      // 65 bytes: 0x04 || X || Y

    init?() {
        let privAttrs: [String: Any] = [kSecAttrIsPermanent as String: false]
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                    kSecAttrKeySizeInBits as String: 256,
                                    kSecPrivateKeyAttrs as String: privAttrs]
        var err: Unmanaged<CFError>?
        guard let k = SecKeyCreateRandomKey(attrs as CFDictionary, &err),
              let pub = SecKeyCopyPublicKey(k),
              let ext = SecKeyCopyExternalRepresentation(pub, &err) as Data?,
              ext.count == 65, ext[ext.startIndex] == 4 else { return nil }
        privateKey = k
        publicKeyX963 = ext
    }

    /// Raw ECDH shared secret (the 32-byte x coordinate, same as CryptoKit's SharedSecret bytes). Nil for invalid peer keys.
    func sharedSecret(peerX963: Data) -> Data? {
        guard peerX963.count == 65, peerX963[peerX963.startIndex] == 4 else { return nil }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                                    kSecAttrKeySizeInBits as String: 256]
        var err: Unmanaged<CFError>?
        guard let peer = SecKeyCreateWithData(peerX963 as CFData, attrs as CFDictionary, &err),
              let result = SecKeyCopyKeyExchangeResult(privateKey, SecKeyAlgorithm.ecdhKeyExchangeStandard, peer,
                                                       [String: Any]() as CFDictionary, &err) as Data?,
              result.count == 32 else { return nil }
        return result
    }
}

// MARK: - Pairing

enum PairingCrypto {
    static func sha256(_ parts: Data...) -> Data {
        var all = [UInt8]()
        for p in parts { all.append(contentsOf: [UInt8](p)) }
        return Data(LegacyHash.sha256(all))
    }

    static func keyId(_ secret: Data) -> Data { Data(sha256(Data("lumen-keyid".utf8), secret).prefix(8)) }

    static func random(_ n: Int) -> Data {
        var b = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &b)
        return Data(b)
    }

    static func code(pkC: Data, pkH: Data, nonceC: Data, nonceH: Data) -> String {
        let d = sha256(Data("lumen-sas-v1".utf8), pkC, pkH, nonceC, nonceH)
        var v: UInt32 = 0
        for byte in d.prefix(4) { v = (v << 8) | UInt32(byte) }
        return String(format: "%05d", v % 100000)
    }

    static func secret(ecdh: Data, nonceC: Data, nonceH: Data) -> Data {
        var salt = nonceC
        salt.append(nonceH)
        return Data(LegacyHash.hkdf(ikm: [UInt8](ecdh), salt: [UInt8](salt), info: [UInt8]("lumen-pair-v1".utf8), length: 32))
    }

    /// "12345" -> "12345"; accepts digits with any separators. Nil unless exactly 5 digits.
    static func parseCode(_ text: String) -> String? {
        let d = text.filter { $0.isASCII && $0.isNumber }
        return d.count == 5 ? d : nil
    }
}

/// Client side of pairing.
final class PairingClient {
    private let key: P256Agreement?
    private let nonce = PairingCrypto.random(16)
    private(set) var code: String?
    private(set) var secret: Data?

    init() { key = P256Agreement() }

    var publicKey: Data { key?.publicKeyX963 ?? Data(count: 65) }

    /// Payload of the first pair packet.
    func start(deviceName: String) -> Data {
        var d = Data([1])
        d.append(PairingCrypto.sha256(publicKey, nonce))
        d.append(Data(deviceName.utf8.prefix(40)))
        return d
    }

    /// Process the host's step 2. Returns the step-3 payload; `code` and `secret` are then available.
    func handleStep2(_ payload: Data) -> Data? {
        let b = [UInt8](payload)
        guard let k = key, b.count == 1 + 65 + 16, b[0] == 2,
              let shared = k.sharedSecret(peerX963: Data(b[1..<66])) else { return nil }
        let pkH = Data(b[1..<66]), nonceH = Data(b[66..<82])
        code = PairingCrypto.code(pkC: publicKey, pkH: pkH, nonceC: nonce, nonceH: nonceH)
        secret = PairingCrypto.secret(ecdh: shared, nonceC: nonce, nonceH: nonceH)
        var d = Data([3])
        d.append(publicKey)
        d.append(nonce)
        return d
    }
}

// MARK: - Replay window / secure session

/// Duplicate / replay filter for sealed packets (applied only after a packet authenticated).
struct ReplayWindow {
    private var highest: UInt64 = 0
    private var seen = Set<UInt64>()
    private let span: UInt64 = 1024

    mutating func accept(_ seq: UInt64) -> Bool {
        if seq + span <= highest { return false }
        if seen.contains(seq) { return false }
        seen.insert(seq)
        if seq > highest {
            highest = seq
            if seen.count > 2048 {
                let h = highest, s = span
                seen = seen.filter { $0 + s > h }
            }
        }
        return true
    }
}

final class SecureSession {
    private static let version: UInt8 = 2
    private static let sealedMagic: [UInt8] = [0x4C, 0x45]

    private let isClient: Bool
    private let psk: Data
    private let agreement: P256Agreement?
    private var myNonce: Data
    private var sendKey: AESGCM?
    private var recvKey: AESGCM?
    private var sendSeq: UInt64 = 0
    private var window = ReplayWindow()
    private let lock = NSLock()

    private(set) var isReady = false

    private init(isClient: Bool, psk: Data) {
        self.isClient = isClient
        self.psk = psk
        agreement = P256Agreement()
        myNonce = PairingCrypto.random(16)
    }

    // MARK: Handshake

    /// Client: start a handshake with the long-term secret from pairing. Send `clientHello` in a handshake packet,
    /// then pass the host's reply to `finish`.
    static func client(pairingKey: Data) -> (session: SecureSession, clientHello: Data) {
        let s = SecureSession(isClient: true, psk: pairingKey)
        var hello = Data([0, version])
        hello.append(s.agreement?.publicKeyX963 ?? Data(count: 65))
        hello.append(s.myNonce)
        hello.append(PairingCrypto.keyId(pairingKey))
        return (s, hello)
    }

    /// True when a host reply says "this device is not paired" (the stored secret is unknown to the host).
    static func isPairingRequired(_ reply: Data) -> Bool {
        let b = [UInt8](reply)
        return b.count >= 2 && b[0] == 2
    }

    /// Client: process the host's handshake reply. Returns false if it is malformed.
    func finish(serverReply: Data) -> Bool {
        let b = [UInt8](serverReply)
        guard isClient, b.count == 2 + 65 + 16, b[0] == 1, b[1] == SecureSession.version else { return false }
        return derive(peerPublic: Data(b[2..<67]), clientNonce: myNonce, serverNonce: Data(b[67..<83]))
    }

    /// Host side (only used by the self-test): accept a client's handshake using the secret that belongs to its key id.
    static func accept(clientHello: Data, secret: Data) -> (session: SecureSession, reply: Data)? {
        let b = [UInt8](clientHello)
        guard b.count == 2 + 65 + 16 + 8, b[0] == 0, b[1] == version else { return nil }
        let s = SecureSession(isClient: false, psk: secret)
        guard s.derive(peerPublic: Data(b[2..<67]), clientNonce: Data(b[67..<83]), serverNonce: s.myNonce) else { return nil }
        var reply = Data([1, version])
        reply.append(s.agreement?.publicKeyX963 ?? Data(count: 65))
        reply.append(s.myNonce)
        return (s, reply)
    }

    private func derive(peerPublic: Data, clientNonce: Data, serverNonce: Data) -> Bool {
        guard let agreement = agreement, let secret = agreement.sharedSecret(peerX963: peerPublic) else { return false }
        var ikm = [UInt8](secret)
        ikm.append(contentsOf: [UInt8](psk))
        var salt = [UInt8](clientNonce)
        salt.append(contentsOf: [UInt8](serverNonce))
        let c2s = LegacyHash.hkdf(ikm: ikm, salt: salt, info: [UInt8]("lumen-v1 c2s".utf8), length: 32)
        let s2c = LegacyHash.hkdf(ikm: ikm, salt: salt, info: [UInt8]("lumen-v1 s2c".utf8), length: 32)
        guard let c2sKey = AESGCM(key: c2s), let s2cKey = AESGCM(key: s2c) else { return false }
        sendKey = isClient ? c2sKey : s2cKey
        recvKey = isClient ? s2cKey : c2sKey
        isReady = true
        return true
    }

    // MARK: Sealing

    static func isSealed(_ d: Data) -> Bool {
        d.count >= 2 && d[d.startIndex] == sealedMagic[0] && d[d.startIndex + 1] == sealedMagic[1]
    }

    private static func be64(_ v: UInt64) -> [UInt8] {
        var out = [UInt8]()
        for i in 0..<8 { out.append(UInt8(truncatingIfNeeded: v >> UInt64(56 - 8 * i))) }
        return out
    }

    private static func nonce(for seq: UInt64) -> [UInt8] {
        return [0, 0, 0, 0] + be64(seq)
    }

    /// Encrypts one Lumen packet. Returns nil if the handshake has not completed.
    func seal(_ packet: Data) -> Data? {
        guard isReady, let key = sendKey else { return nil }
        lock.lock(); sendSeq += 1; let seq = sendSeq; lock.unlock()
        let header: [UInt8] = SecureSession.sealedMagic + SecureSession.be64(seq)
        guard let box = key.seal(nonce: SecureSession.nonce(for: seq), aad: header, plaintext: [UInt8](packet)) else { return nil }
        var out = Data(header)
        out.append(contentsOf: box.ciphertext)
        out.append(contentsOf: box.tag)
        return out
    }

    /// Decrypts and authenticates a sealed packet. Returns nil for forged, corrupted or replayed packets.
    func open(_ sealed: Data) -> Data? {
        let b = [UInt8](sealed)
        guard isReady, let key = recvKey, b.count >= 10 + 16, b[0] == 0x4C, b[1] == 0x45 else { return nil }
        var seq: UInt64 = 0
        for i in 2..<10 { seq = (seq << 8) | UInt64(b[i]) }
        let header = Array(b[0..<10])
        let ct = Array(b[10..<(b.count - 16)])
        let tag = Array(b[(b.count - 16)...])
        guard let plain = key.open(nonce: SecureSession.nonce(for: seq), aad: header, ciphertext: ct, tag: tag) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard window.accept(seq) else { return nil }
        return Data(plain)
    }
}

// MARK: - Self-test

/// Known-answer tests (NIST / McGrew-Viega GCM test cases 13-16, RFC 5869 HKDF case 1, RFC 4231 HMAC case 2)
/// plus an in-process ECDH + handshake + seal/open round trip. Run at app start; `run()` returns a failure text or nil.
enum CryptoSelfTest {
    private static func hex(_ s: String) -> [UInt8] {
        var out = [UInt8]()
        var chars = Array(s)
        while chars.count >= 2 {
            let pair = String(chars[0..<2])
            chars.removeFirst(2)
            if let v = UInt8(pair, radix: 16) { out.append(v) }
        }
        return out
    }

    private static func hexString(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

    private static func gcmCase(_ name: String, key: String, iv: String, aad: String, pt: String, ct: String, tag: String) -> String? {
        guard let g = AESGCM(key: hex(key)) else { return "\(name): key" }
        guard let r = g.seal(nonce: hex(iv), aad: hex(aad), plaintext: hex(pt)) else { return "\(name): seal" }
        if hexString(r.ciphertext) != ct { return "\(name): ciphertext" }
        if hexString(r.tag) != tag { return "\(name): tag" }
        guard let back = g.open(nonce: hex(iv), aad: hex(aad), ciphertext: r.ciphertext, tag: r.tag), hexString(back) == pt else { return "\(name): open" }
        var bad = r.tag
        bad[0] ^= 1
        if g.open(nonce: hex(iv), aad: hex(aad), ciphertext: r.ciphertext, tag: bad) != nil { return "\(name): forged tag accepted" }
        return nil
    }

    static func run() -> String? {
        let zero32 = String(repeating: "00", count: 32)
        let zero12 = String(repeating: "00", count: 12)
        if let e = gcmCase("gcm13", key: zero32, iv: zero12, aad: "", pt: "", ct: "", tag: "530f8afbc74536b9a963b4f1c4cb738b") { return e }
        if let e = gcmCase("gcm14", key: zero32, iv: zero12, aad: "", pt: String(repeating: "00", count: 16),
                           ct: "cea7403d4d606b6e074ec5d3baf39d18", tag: "d0d1c8a799996bf0265b98b5d48ab919") { return e }
        let key = "feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308"
        let iv = "cafebabefacedbaddecaf888"
        let p64 = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255"
        if let e = gcmCase("gcm15", key: key, iv: iv, aad: "", pt: p64,
                           ct: "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad",
                           tag: "b094dac5d93471bdec1a502270e3cc6c") { return e }
        let p60 = String(p64.prefix(120))
        if let e = gcmCase("gcm16", key: key, iv: iv, aad: "feedfacedeadbeeffeedfacedeadbeefabaddad2", pt: p60,
                           ct: "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662",
                           tag: "76fc6ece0f4e1768cddf8853bb2d551b") { return e }

        // RFC 4231 test case 2 (HMAC-SHA-256)
        let mac = LegacyHash.hmacSHA256(key: [UInt8]("Jefe".utf8), data: [UInt8]("what do ya want for nothing?".utf8))
        if hexString(mac) != "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" { return "hmac" }
        // RFC 5869 test case 1 (HKDF-SHA-256)
        let okm = LegacyHash.hkdf(ikm: [UInt8](repeating: 0x0b, count: 22), salt: hex("000102030405060708090a0b0c"),
                                  info: hex("f0f1f2f3f4f5f6f7f8f9"), length: 42)
        if hexString(okm) != "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865" { return "hkdf" }
        if hexString(LegacyHash.sha256([UInt8]("abc".utf8))) != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" { return "sha256" }

        // ECDH both ways must agree, then a full handshake with sealed packets in both directions.
        guard let a = P256Agreement(), let b = P256Agreement(),
              let s1 = a.sharedSecret(peerX963: b.publicKeyX963), let s2 = b.sharedSecret(peerX963: a.publicKeyX963),
              s1 == s2 else { return "ecdh" }
        let psk = PairingCrypto.random(32)
        let (client, hello) = SecureSession.client(pairingKey: psk)
        guard let (host, reply) = SecureSession.accept(clientHello: hello, secret: psk), client.finish(serverReply: reply) else { return "handshake" }
        let msg = Data("lumen self test".utf8)
        guard let sealed = client.seal(msg), sealed.count == 10 + msg.count + 16, let opened = host.open(sealed), opened == msg else { return "seal c2s" }
        if host.open(sealed) != nil { return "replay accepted" }
        guard let sealed2 = host.seal(msg), let opened2 = client.open(sealed2), opened2 == msg else { return "seal s2c" }
        return nil
    }
}
