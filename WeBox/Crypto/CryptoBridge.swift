//
//  CryptoBridge.swift
//  WeBox for iOS
//
//  Native implementation of the Widget.crypto surface (crypto.aes / crypto.hash /
//  crypto.hmac / crypto.encode / crypto.random / crypto.rsa). Messages match the
//  Android host so script level error handling keeps working unchanged.
//

import Foundation
import CommonCrypto
import CryptoKit
import Security

enum CryptoError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

enum TextEncoding: String {
    case utf8, base64, hex, latin1

    static func parse(_ raw: String?) -> TextEncoding {
        switch (raw ?? "utf8").lowercased() {
        case "base64": return .base64
        case "hex": return .hex
        case "latin1", "binary": return .latin1
        default: return .utf8
        }
    }

    func decode(_ text: String) throws -> Data {
        switch self {
        case .utf8:
            return Data(text.utf8)
        case .latin1:
            return Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
        case .base64:
            let cleaned = text.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")
            guard let data = Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters]) else {
                throw CryptoError.message("Base64 格式不正确")
            }
            return data
        case .hex:
            return try Self.hexToData(text)
        }
    }

    func encode(_ data: Data) -> String {
        switch self {
        case .utf8:
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        case .latin1:
            return String(data.map { Character(UnicodeScalar($0)) })
        case .base64:
            return data.base64EncodedString()
        case .hex:
            return data.map { String(format: "%02x", $0) }.joined()
        }
    }

    static func hexToData(_ text: String) throws -> Data {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { throw CryptoError.message("字节编码无效") }
        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                throw CryptoError.message("字节编码无效")
            }
            data.append(byte)
            index = next
        }
        return data
    }
}

enum CryptoBridge {
    // MARK: - AES

    static func aes(text: String,
                    key: String,
                    iv: String,
                    mode: String,
                    padding: String,
                    keyEncoding: String?,
                    ivEncoding: String?,
                    inputEncoding: String?,
                    outputEncoding: String?,
                    decrypt: Bool) throws -> String {
        let keyData = try TextEncoding.parse(keyEncoding).decode(key)
        guard [16, 24, 32].contains(keyData.count) else {
            throw CryptoError.message("AES 密钥需要 16、24 或 32 字节")
        }
        let ivData = try TextEncoding.parse(ivEncoding).decode(iv)
        let input = try TextEncoding.parse(inputEncoding).decode(text)
        let output = TextEncoding.parse(outputEncoding)

        let normalizedMode = mode.uppercased()
        let normalizedPadding = padding.uppercased()
        let isNoPadding = normalizedPadding == "NOPADDING" || normalizedPadding == "NO_PADDING" || normalizedPadding.isEmpty

        if normalizedMode == "GCM" {
            return try aesGCM(input: input, key: keyData, iv: ivData, decrypt: decrypt, output: output)
        }

        var algorithm: CCAlgorithm = CCAlgorithm(kCCAlgorithmAES)
        var options: CCOptions = 0
        switch normalizedMode {
        case "CBC": algorithm = CCAlgorithm(kCCAlgorithmAES)
        case "ECB": algorithm = CCAlgorithm(kCCAlgorithmAES); options |= CCOptions(kCCOptionECBMode)
        case "CTR": algorithm = CCAlgorithm(kCCAlgorithmAES)
        default: throw CryptoError.message("不支持的 AES 模式")
        }
        switch normalizedPadding {
        case "NOPADDING", "NO_PADDING", "":
            break
        case "PKCS7", "PKCS5", "PKCS5PADDING", "PKCS7PADDING":
            options |= CCOptions(kCCOptionPKCS7Padding)
        default:
            throw CryptoError.message("不支持的 AES 填充")
        }

        if normalizedMode == "CTR" {
            return try aesCTR(input: input, key: keyData, iv: ivData, decrypt: decrypt, output: output)
        }

        let operation = decrypt ? CCOperation(kCCDecrypt) : CCOperation(kCCEncrypt)
        let ivPointer = normalizedMode == "ECB" || ivData.isEmpty ? nil : [UInt8](ivData)
        var buffer = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(operation,
                             algorithm,
                             options,
                             [UInt8](keyData), keyData.count,
                             ivPointer,
                             [UInt8](input), input.count,
                             &buffer, buffer.count,
                             &moved)
        guard status == CCCryptorStatus(kCCSuccess) else {
            if status == CCCryptorStatus(kCCDecodeError) {
                throw CryptoError.message(decrypt ? "AES 解密失败，请检查密钥或密文" : "AES 加密失败")
            }
            throw CryptoError.message("AES 处理失败（\(status)）")
        }
        return output.encode(Data(buffer.prefix(moved)))
    }

    private static func aesCTR(input: Data, key: Data, iv: Data, decrypt: Bool, output: TextEncoding) throws -> String {
        var cryptorRef: CCCryptorRef?
        var keyBytes = [UInt8](key)
        var ivBytes = [UInt8](iv)
        let status = CCCryptorCreateWithMode(CCOperation(kCCEncrypt),
                                             CCMode(kCCModeCTR),
                                             CCAlgorithm(kCCAlgorithmAES),
                                             CCPadding(ccNoPadding),
                                             ivBytes, keyBytes, key.count,
                                             nil, 0, 0,
                                             CCModeOptions(kCCModeOptionCTR_BE),
                                             &cryptorRef)
        guard status == CCCryptorStatus(kCCSuccess), let ref = cryptorRef else {
            throw CryptoError.message("AES/CTR 初始化失败")
        }
        defer { CCCryptorRelease(ref) }
        return try process(cryptor: ref, input: input, output: output)
    }

    private static func aesGCM(input: Data, key: Data, iv: Data, decrypt: Bool, output: TextEncoding) throws -> String {
        let symmetricKey = SymmetricKey(data: key)
        if decrypt {
            guard input.count > 16 else { throw CryptoError.message("AES 解密失败，请检查密钥或密文") }
            let ciphertext = input.prefix(input.count - 16)
            let tag = input.suffix(16)
            do {
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv),
                                                ciphertext: ciphertext,
                                                tag: tag)
                let opened = try AES.GCM.open(box, using: symmetricKey)
                return output.encode(opened)
            } catch {
                throw CryptoError.message("认证解密失败，密钥不匹配或文件已损坏")
            }
        } else {
            do {
                let box = try AES.GCM.seal(input, using: symmetricKey, nonce: AES.GCM.Nonce(data: iv))
                return output.encode(box.ciphertext + box.tag)
            } catch {
                throw CryptoError.message("AES 加密失败")
            }
        }
    }

    private static func process(cryptor: CCCryptorRef, input: Data, output: TextEncoding) throws -> String {
        var buffer = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = input.withUnsafeBytes { raw -> CCCryptorStatus in
            guard let base = raw.baseAddress else { return CCCryptorStatus(kCCSuccess) }
            return CCCryptorUpdate(cryptor, base, input.count, &buffer, buffer.count, &moved)
        }
        guard status == CCCryptorStatus(kCCSuccess) else {
            throw CryptoError.message("AES 处理失败（\(status)）")
        }
        var finalMoved = 0
        let finalStatus = CCCryptorFinal(cryptor, &buffer, buffer.count, &finalMoved)
        guard finalStatus == CCCryptorStatus(kCCSuccess) else {
            throw CryptoError.message("AES 处理失败（\(finalStatus)）")
        }
        return output.encode(Data(buffer.prefix(moved + finalMoved)))
    }

    // MARK: - Hash / HMAC

    static func hash(algorithm: String, text: String, inputEncoding: String?, outputEncoding: String?) throws -> String {
        let data = try TextEncoding.parse(inputEncoding).decode(text)
        let digest: Data
        switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
        case "MD5":
            digest = Self.makeDigest(data, length: Int(CC_MD5_DIGEST_LENGTH)) { data, length, out in
                CC_MD5(data, CC_LONG(length), out)
            }
        case "SHA1":
            digest = Self.makeDigest(data, length: Int(CC_SHA1_DIGEST_LENGTH)) { data, length, out in
                CC_SHA1(data, CC_LONG(length), out)
            }
        case "SHA256":
            digest = Self.makeDigest(data, length: Int(CC_SHA256_DIGEST_LENGTH)) { data, length, out in
                CC_SHA256(data, CC_LONG(length), out)
            }
        case "SHA384":
            digest = Self.makeDigest(data, length: Int(CC_SHA384_DIGEST_LENGTH)) { data, length, out in
                CC_SHA384(data, CC_LONG(length), out)
            }
        case "SHA512":
            digest = Self.makeDigest(data, length: Int(CC_SHA512_DIGEST_LENGTH)) { data, length, out in
                CC_SHA512(data, CC_LONG(length), out)
            }
        default:
            throw CryptoError.message("不支持的摘要算法")
        }
        return TextEncoding.parse(outputEncoding ?? "hex").encode(digest)
    }

    static func hmac(algorithm: String, text: String, key: String, keyEncoding: String?,
                     inputEncoding: String?, outputEncoding: String?) throws -> String {
        let data = try TextEncoding.parse(inputEncoding).decode(text)
        let keyData = try TextEncoding.parse(keyEncoding).decode(key)
        let normalized = algorithm.uppercased().replacingOccurrences(of: "-", with: "")
        let ccAlgorithm: CCHmacAlgorithm
        let length: Int
        switch normalized {
        case "MD5": ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgMD5); length = Int(CC_MD5_DIGEST_LENGTH)
        case "SHA1": ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA1); length = Int(CC_SHA1_DIGEST_LENGTH)
        case "SHA256": ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA256); length = Int(CC_SHA256_DIGEST_LENGTH)
        case "SHA384": ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA384); length = Int(CC_SHA384_DIGEST_LENGTH)
        case "SHA512": ccAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA512); length = Int(CC_SHA512_DIGEST_LENGTH)
        default: throw CryptoError.message("不支持的 HMAC 算法")
        }
        var digest = [UInt8](repeating: 0, count: length)
        keyData.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(ccAlgorithm, keyBytes.baseAddress, keyData.count, dataBytes.baseAddress, data.count, &digest)
            }
        }
        return TextEncoding.parse(outputEncoding ?? "hex").encode(Data(digest))
    }

    static func md5Hex(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = Self.makeDigest(data, length: Int(CC_MD5_DIGEST_LENGTH)) { data, length, out in
            CC_MD5(data, CC_LONG(length), out)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func makeDigest(_ data: Data,
                                   length: Int,
                                   _ function: (UnsafeRawPointer?, Int, UnsafeMutablePointer<UInt8>?) -> UnsafeMutablePointer<UInt8>?) -> Data {
        var digest = [UInt8](repeating: 0, count: length)
        data.withUnsafeBytes { raw in
            _ = digest.withUnsafeMutableBytes { out in
                function(raw.baseAddress, data.count, out.baseAddress?.assumingMemoryBound(to: UInt8.self))
            }
        }
        return Data(digest)
    }

    // MARK: - Encoding

    static func encode(text: String, from: String, to: String) throws -> String {
        let data = try TextEncoding.parse(from).decode(text)
        return TextEncoding.parse(to).encode(data)
    }

    static func randomData(size: Int) throws -> Data {
        guard size > 0, size <= 1024 * 1024 else { throw CryptoError.message("随机数据长度无效") }
        var bytes = [UInt8](repeating: 0, count: size)
        let status = SecRandomCopyBytes(kSecRandomDefault, size, &bytes)
        guard status == errSecSuccess else { throw CryptoError.message("随机数生成失败") }
        return Data(bytes)
    }

    // MARK: - RSA

    static func rsa(text: String, key: String, decrypt: Bool) throws -> String {
        guard let secKey = try? loadKey(pem: key, isPrivate: decrypt) else {
            throw CryptoError.message("RSA 密钥格式无效")
        }
        let input: Data
        if decrypt {
            guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  options: [.ignoreUnknownCharacters]) else {
                throw CryptoError.message("Base64 格式不正确")
            }
            input = data
        } else {
            input = Data(text.utf8)
        }
        let algorithm: SecKeyAlgorithm = decrypt ? .rsaEncryptionPKCS1 : .rsaEncryptionPKCS1
        guard SecKeyIsAlgorithmSupported(secKey, decrypt ? .decrypt : .encrypt, algorithm) else {
            throw CryptoError.message("RSA 算法不受支持")
        }
        let output: Data
        do {
            if decrypt {
                var error: Unmanaged<CFError>?
                guard let result = SecKeyCreateDecryptedData(secKey, algorithm, input as CFData, &error) else {
                    throw CryptoError.message("RSA 解密失败")
                }
                output = result as Data
            } else {
                var error: Unmanaged<CFError>?
                guard let result = SecKeyCreateEncryptedData(secKey, algorithm, input as CFData, &error) else {
                    throw CryptoError.message("RSA 加密失败")
                }
                output = result as Data
            }
        }
        return output.base64EncodedString()
    }

    private static func loadKey(pem: String, isPrivate: Bool) throws -> SecKey {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let data = Data(base64Encoded: stripped, options: [.ignoreUnknownCharacters]) else {
            throw CryptoError.message("RSA 密钥格式无效")
        }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: isPrivate ? kSecAttrKeyClassPrivate : kSecAttrKeyClassPublic
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(data as CFData, attributes as CFDictionary, &error) else {
            throw CryptoError.message("RSA 密钥格式无效")
        }
        return key
    }
}
