import CommonCrypto
import Foundation

enum DESCipher {
    static func decryptECB(ciphertext: Data, asciiKey: Data) throws -> Data {
        guard asciiKey.count == kCCKeySizeDES else {
            throw BeanfunError.parse("DES key 必須是 8 bytes")
        }
        guard !ciphertext.isEmpty, ciphertext.count.isMultiple(of: kCCBlockSizeDES) else {
            throw BeanfunError.parse("DES 密文長度必須是 8 的倍數")
        }

        var output = Data(count: ciphertext.count + kCCBlockSizeDES)
        let outputCapacity = output.count
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                asciiKey.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress,
                        asciiKey.count,
                        nil,
                        cipherBytes.baseAddress,
                        ciphertext.count,
                        outputBytes.baseAddress,
                        outputCapacity,
                        &outputLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw BeanfunError.parse("CommonCrypto DES 解密失敗（status \(status)）")
        }
        output.removeSubrange(outputLength..<output.count)
        return removePadding(output)
    }

    private static func removePadding(_ data: Data) -> Data {
        guard let last = data.last else { return data }
        let padding = Int(last)
        if (1...kCCBlockSizeDES).contains(padding),
           data.suffix(padding).allSatisfy({ $0 == last }) {
            return data.dropLast(padding)
        }
        var output = data
        while output.last == 0 {
            output.removeLast()
        }
        return output
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
