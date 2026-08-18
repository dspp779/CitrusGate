import Foundation

/// Offline `Command.DecryptParam` for `gamaniagames://…&&&&Data=…` (Cmd 06004/06006).
enum GGMDataParam {
    static let substitutionTables = [
        "18EA0FD239BBD938",
        "bac987d65e432f10",
        "3bc4d5e6f2a79108",
        "cdbeaf9012456378",
        "4e6fb81a3c5d7092",
        "bdef1246789ac530",
        "5f82cb4093e71d6a",
        "df1468ace0357b92",
    ]

    static func decryptParam(_ data: String) throws -> [String: String] {
        guard let first = data.first, first.isHexDigit,
              let offset = Int(String(first), radix: 16), (0...15).contains(offset) else {
            throw BeanfunError.parse("Data 偏移量無效")
        }
        guard data.count > 1 else {
            throw BeanfunError.parse("Data 太短")
        }
        // Table 0 in the protocol doc is not a hex permutation. Live 06006
        // payloads decode with tables[1 + offset % 4] (tables 1–4).
        let tableIndex = 1 + (offset % 4)
        let table = substitutionTables[tableIndex]
        var hexDigits: [Character] = []
        hexDigits.reserveCapacity(data.count - 1)
        for character in data.dropFirst() {
            guard let index = table.firstIndex(of: character) else {
                throw BeanfunError.parse("Data 字元 \(character) 不在代換表 \(tableIndex) 中")
            }
            let nibble = table.distance(from: table.startIndex, to: index)
            hexDigits.append(nibbleHexCharacter(nibble))
        }
        let hexPayload = String(hexDigits)
        let keyStart = offset + 1
        guard keyStart + 8 <= hexPayload.count else {
            throw BeanfunError.parse("Data 還原後長度不足以提取 DES key")
        }
        let desKey = String(hexPayload.dropFirst(keyStart).prefix(8))
        let cipherHex = String(hexPayload.prefix(keyStart) + hexPayload.dropFirst(keyStart + 8))
        guard let encrypted = Data(hexString: cipherHex) else {
            throw BeanfunError.parse("Data 還原後的 DES 密文不是合法 hex")
        }
        let plaintext = try DESCipher.decryptECB(
            ciphertext: encrypted,
            asciiKey: Data(desKey.utf8)
        )
        guard var text = String(data: plaintext, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) else {
            throw BeanfunError.parse("Data 解密結果不是 UTF-8")
        }
        while text.last == "\0" {
            text.removeLast()
        }
        var params: [String: String] = [:]
        let pieces = text.split { $0 == ";" || $0 == "&" || $0 == "\n" }
        for pair in pieces {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<separator])
            let value = String(pair[pair.index(after: separator)...])
            if !key.isEmpty {
                params[key] = value
            }
        }
        guard !params.isEmpty else {
            throw BeanfunError.parse("Data 解密後沒有鍵值對")
        }
        return params
    }

    static func launchTicket(from data: String) throws -> String {
        let params = try decryptParam(data)
        guard let launchTicket = params["LaunchTicket"],
              launchTicket.count == 64,
              launchTicket.allSatisfy(\.isHexDigit) else {
            throw BeanfunError.parse("Data 解密後缺少 64 字元 LaunchTicket")
        }
        return launchTicket
    }

    static func decryptOTPEnvelope(_ envelope: String) throws -> String {
        guard envelope.count >= 40 else {
            throw BeanfunError.parse("OTP envelope 太短")
        }
        let keyText = String(envelope.prefix(8))
        let encryptedText = String(envelope.dropFirst(8))
        guard let key = keyText.data(using: .ascii),
              let encrypted = Data(hexString: encryptedText) else {
            throw BeanfunError.parse("OTP envelope 的 DES key 或密文無效")
        }
        let plaintext = try DESCipher.decryptECB(ciphertext: encrypted, asciiKey: key)
        guard let otp = String(data: plaintext, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
              !otp.isEmpty else {
            throw BeanfunError.parse("OTP 解密結果不是 UTF-8")
        }
        return otp
    }

    private static func nibbleHexCharacter(_ value: Int) -> Character {
        precondition((0...15).contains(value))
        return Character(String(value, radix: 16))
    }
}
