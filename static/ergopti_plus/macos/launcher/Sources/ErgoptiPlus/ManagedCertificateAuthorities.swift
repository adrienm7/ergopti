// Sources/ErgoptiPlus/ManagedCertificateAuthorities.swift
// Request-owned extra anchors preserve native account/system trust.

import Darwin
import Foundation
import Security

enum ManagedCertificateAuthorities {
	enum Refusal: Error { case certificate }

	/// Certificate data is bounded independently of the network request. These
	/// paths arrive only from the admitted immutable private bootstrap snapshot.
	static func load(environment: [String: String]) throws -> [SecCertificate] {
		let names = ManagedNetworkBootstrapPolicy.trustEnvironment
		var bytesRead = 0
		var filesRead = 0
		var certificates: [SecCertificate] = []
		func read(_ path: String) throws {
			guard !path.isEmpty, !path.utf8.contains(0), filesRead < ManagedNetworkBootstrapPolicy.maximumCertificateFiles else { throw Refusal.certificate }
			filesRead += 1
			// Stock Go certificate directories permit hashed symlink entries. The
			// resolved regular FD owns only certificate data, never executable or
			// source authority, and is held through the bounded read and close.
			let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
			guard descriptor >= 0 else { throw Refusal.certificate }
			var owned = descriptor
			defer { if owned >= 0 { Darwin.close(owned) } }
			var identity = stat()
			let available = ManagedNetworkBootstrapPolicy.maximumCertificateBytes - bytesRead
			guard fstat(descriptor, &identity) == 0, (identity.st_mode & S_IFMT) == S_IFREG,
				identity.st_size > 0, identity.st_size <= available else { throw Refusal.certificate }
			var data = Data()
			var bytes = [UInt8](repeating: 0, count: 8192)
			while true {
				let count = Darwin.read(descriptor, &bytes, min(bytes.count, available - data.count + 1))
				if count < 0 && errno == EINTR { continue }
				guard count >= 0 else { throw Refusal.certificate }
				if count == 0 { break }
				guard count <= available - data.count else { throw Refusal.certificate }
				data.append(contentsOf: bytes.prefix(count))
			}
			owned = -1
			guard Darwin.close(descriptor) == 0, data.count == identity.st_size,
				let text = String(data: data, encoding: .utf8) else { throw Refusal.certificate }
			bytesRead += data.count
			certificates += try decodePEM(text)
		}
		if let file = environment[names[0]], !file.isEmpty { try read(file) }
		if let value = environment[names[1]], !value.isEmpty {
			for path in value.components(separatedBy: ":") {
				guard !path.isEmpty, !path.utf8.contains(0) else { throw Refusal.certificate }
				let entries = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
				guard entries.count <= ManagedNetworkBootstrapPolicy.maximumCertificateFiles - filesRead else { throw Refusal.certificate }
				for entry in entries {
					let file = (path as NSString).appendingPathComponent(entry)
					var directory = ObjCBool(false)
					if FileManager.default.fileExists(atPath: file, isDirectory: &directory), directory.boolValue { continue }
					try read(file)
				}
			}
		}
		if names.contains(where: { !(environment[$0] ?? "").isEmpty }), certificates.isEmpty { throw Refusal.certificate }
		return certificates
	}

	static func decodePEM(_ text: String) throws -> [SecCertificate] {
		let opening = "-----BEGIN CERTIFICATE-----"
		let closing = "-----END CERTIFICATE-----"
		var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
		var result: [SecCertificate] = []
		while !remaining.isEmpty {
			guard remaining.hasPrefix(opening), let end = remaining.range(of: closing) else { throw Refusal.certificate }
			let encoded = remaining[remaining.index(remaining.startIndex, offsetBy: opening.count)..<end.lowerBound]
			let compact = encoded.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
			guard let bytes = Data(base64Encoded: compact), !bytes.isEmpty,
				let certificate = SecCertificateCreateWithData(nil, bytes as CFData) else { throw Refusal.certificate }
			result.append(certificate)
			remaining = String(remaining[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
		}
		guard !result.isEmpty else { throw Refusal.certificate }
		return result
	}

	/// Keep the server's existing hostname policies and account anchors. Adding
	/// an enterprise CA never turns a failed trust evaluation into success.
	static func evaluate(_ trust: SecTrust, adding certificates: [SecCertificate]) -> Bool {
		guard !certificates.isEmpty,
			SecTrustSetAnchorCertificates(trust, certificates as CFArray) == errSecSuccess,
			SecTrustSetAnchorCertificatesOnly(trust, false) == errSecSuccess else { return false }
		return SecTrustEvaluateWithError(trust, nil)
	}
}
