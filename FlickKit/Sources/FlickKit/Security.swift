import Foundation
import Network
import CryptoKit
import Security

/// TLS 1.2 with a pre-shared key. Pairing uses a key derived from the 6-digit code shown
/// on the Mac; after pairing the Mac hands over a long random secret used from then on.
public enum FlickSecurity {
    public static func pairingKey(code: String) -> Data {
        derive(Data(code.utf8), label: "flick-pair-v1")
    }

    public static func sessionKey(secret: Data) -> Data {
        derive(secret, label: "flick-session-v1")
    }

    static func derive(_ material: Data, label: String) -> Data {
        let key = SymmetricKey(data: material)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: key)
        return Data(mac)
    }

    public static func randomSecret(bytes: Int = 32) -> Data {
        var d = Data(count: bytes)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return d
    }

    public static func randomCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    public static func parameters(psk: Data, identity: String = "flick") -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let opts = tls.securityProtocolOptions
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let idData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(opts, pskData as __DispatchData, idData as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(opts, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(opts, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(opts, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 6

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true
        params.serviceClass = .interactiveVideo
        return params
    }
}
