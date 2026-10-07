// Standalone TEST-ONLY observer. Never shipped or routed through the launcher.
import CryptoKit
import Darwin
import Foundation
import Security

private enum QueryDiagnosticFailure: Error { case signing, arguments }

@main
private struct ActiveVHDQueryDiagnostic {
	private static let identifier = "com.ergoptiplus.test.vhd-properties"

	private static func leafDigest() throws -> String {
		var code: SecCode?
		guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
			SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
			throw QueryDiagnosticFailure.signing
		}
		var staticCode: SecStaticCode?
		guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
			throw QueryDiagnosticFailure.signing
		}
		var information: CFDictionary?
		guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
			let fields = information as? [String: Any],
			fields[kSecCodeInfoIdentifier as String] as? String == identifier,
			let flags = fields[kSecCodeInfoFlags as String] as? NSNumber,
			flags.uint32Value & UInt32(kSecCodeSignatureAdhoc) == 0,
			let certificates = fields[kSecCodeInfoCertificates as String] as? [SecCertificate],
			let leaf = certificates.first,
			let cms = fields[kSecCodeInfoCMS as String] as? Data, !cms.isEmpty else {
			throw QueryDiagnosticFailure.signing
		}
		let data = SecCertificateCopyData(leaf) as Data
		guard !data.isEmpty, data.count <= 1024 * 1024 else { throw QueryDiagnosticFailure.signing }
		return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	static func main() {
		do {
			guard CommandLine.arguments.count == 1 else { throw QueryDiagnosticFailure.arguments }
			let before = try leafDigest()
			let observation = InstalledVirtualHIDActiveExtensionProbe.observe()
			guard try leafDigest() == before else { throw QueryDiagnosticFailure.signing }
			let data = try JSONEncoder().encode(observation)
			guard var packet = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
				throw QueryDiagnosticFailure.arguments
			}
			packet["error_domain"] = observation.errorDomain.map { $0 as Any } ?? NSNull()
			packet["error_code"] = observation.errorCode.map { $0 as Any } ?? NSNull()
			packet["test_only"] = true
			packet["signing_identifier"] = identifier
			packet["public_leaf_sha256"] = before
			let output = try JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys])
			try FileHandle.standardOutput.write(contentsOf: output + Data([10]))
		} catch {
			try? FileHandle.standardError.write(contentsOf: Data("TEST-ONLY native properties observer refused\n".utf8))
			exit(1)
		}
	}
}
