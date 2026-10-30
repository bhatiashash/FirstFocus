import Foundation
import Security

/// Reads the currently running app bundle's own code-signing identity: the
/// signing certificate's common name, e.g. "FirstFocus Local Dev" — the same
/// value `codesign -dvvv`'s `Authority=` line reports, confirmed stable
/// across rebuilds signed by the same identity (ticket 01). Reading an
/// existing signature is a local, offline verification against the
/// embedded certificate chain; unlike `codesign --sign`, it never touches
/// the keychain's private key and so never prompts.
///
/// Returns `nil` if the bundle can't be inspected — ad-hoc signed,
/// unsigned, or some other introspection failure — rather than throwing.
/// A caller that can't determine a current identity skips the mismatch
/// check entirely instead of treating "unknown" as "changed."
public func currentSigningIdentity(bundlePath: String) -> String? {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: bundlePath) as CFURL, [], &staticCode) == errSecSuccess,
          let code = staticCode
    else { return nil }

    var information: CFDictionary?
    let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
    guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess,
          let info = information as? [String: Any]
    else { return nil }

    guard let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certificates.first
    else { return nil }

    var commonName: CFString?
    guard SecCertificateCopyCommonName(leaf, &commonName) == errSecSuccess else { return nil }
    return commonName as String?
}
