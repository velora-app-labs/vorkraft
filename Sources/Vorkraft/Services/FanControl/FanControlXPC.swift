// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Security
import CryptoKit

enum FanControlIdentifiers {
    // Pin the peer to this process's signing certificate. This supports a
    // Vorkraft Developer ID or a dedicated local signing certificate without
    // trusting the upstream maintainer or arbitrary code with our bundle ID.
    private static let signerRequirement: String = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "never" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return "never" }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &information) == errSecSuccess,
              let values = information as? [String: Any],
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else { return "never" }
        let bytes = SecCertificateCopyData(certificate) as Data
        let digest = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return "certificate leaf = H\"\(digest)\""
    }()

    #if VORKRAFT_DEVELOPMENT
    static let appBundleID = "com.veloraapplabs.vorkraft.dev"
    #else
    static let appBundleID = "com.veloraapplabs.vorkraft"
    #endif

    static let helperID = "\(appBundleID).fan-control"
    static let plistName = "\(helperID).plist"

    static let appCodeRequirement =
        "\(signerRequirement) and identifier \"\(appBundleID)\""
    static let helperCodeRequirement =
        "\(signerRequirement) and identifier \"\(helperID)\""
}

@objc protocol FanControlXPCProtocol {
    func status(withReply reply: @escaping (Data) -> Void)
    func startMaximumCooling(withReply reply: @escaping (Data) -> Void)
    func applyConfiguration(_ configuration: Data, withReply reply: @escaping (Data) -> Void)
    func heartbeat(withReply reply: @escaping (Data) -> Void)
    func restoreAutomatic(withReply reply: @escaping (Data) -> Void)
}

enum FanControlIPC {
    static func encode(_ response: FanControlResponse) -> Data {
        // Every value in this closed response model is JSON encodable. Keeping
        // one deterministic fallback avoids ever violating the XPC reply shape.
        (try? JSONEncoder().encode(response))
            ?? Data(#"{"succeeded":false,"snapshot":{"fans":[],"isCooling":false},"error":"controlFailed"}"#.utf8)
    }

    static func decode(_ data: Data) -> FanControlResponse? {
        try? JSONDecoder().decode(FanControlResponse.self, from: data)
    }

    static func encode(_ configuration: FanControlConfiguration) -> Data? {
        try? JSONEncoder().encode(configuration)
    }

    static func decodeConfiguration(_ data: Data) -> FanControlConfiguration? {
        guard let configuration = try? JSONDecoder().decode(FanControlConfiguration.self,
                                                              from: data),
              FanControlPolicy.validConfiguration(configuration) else { return nil }
        return configuration
    }
}
