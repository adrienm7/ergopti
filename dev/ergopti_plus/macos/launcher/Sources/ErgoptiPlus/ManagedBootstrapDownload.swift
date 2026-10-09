// Sources/ErgoptiPlus/ManagedBootstrapDownload.swift
// Fresh-machine artifact spooling uses the same native request owner as HTTPX.

import CFNetwork
import CoreFoundation
import CryptoKit
import Darwin
import Foundation

struct ManagedBootstrapRequest {
	let url: URL
	let sha256: String
	let output: String
	let timeoutMilliseconds: Int
	let size: Int64?

	static func parse(_ bytes: Data) -> ManagedBootstrapRequest? {
		guard bytes.count <= 65_536,
			let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
			Set(fields.keys).subtracting(["version", "url", "sha256", "output", "timeout_ms", "size"]).isEmpty,
			let version = integer(fields["version"]), version == 1,
			let text = fields["url"] as? String, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
			let url = URL(string: text), acceptable(url),
			let digest = fields["sha256"] as? String, digest.utf8.count == 64,
			digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
			let path = fields["output"] as? String, path.hasPrefix("/"), !path.hasSuffix("/"),
			!path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
			let timeout = integer(fields["timeout_ms"]), timeout > 0, timeout <= Int64(Int32.max)
		else { return nil }
		let size: Int64?
		if let value = fields["size"] {
			guard let parsed = integer(value), parsed > 0 else { return nil }
			size = parsed
		} else { size = nil }
		return ManagedBootstrapRequest(url: url, sha256: digest, output: path,
			timeoutMilliseconds: Int(timeout), size: size)
	}

	static func acceptable(_ url: URL) -> Bool {
		return url.scheme == "https" && url.host?.isEmpty == false && url.user == nil
			&& url.password == nil && url.fragment == nil && (url.port == nil || (1...65535).contains(url.port!))
	}

	static func integer(_ value: Any?) -> Int64? {
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
			String(cString: number.objCType) != "f", String(cString: number.objCType) != "d",
			number.int64Value >= 0, number.stringValue == String(number.int64Value)
		else { return nil }
		return number.int64Value
	}
}

struct ManagedBootstrapPolicy {
	let maximumSelections: Int
	let maximumRedirects: Int
	let bypassOrder: [String]
	let loopbackHosts: [String]
	let loopbackSuffixes: [String]
	let loopbackNetworks: [String]
	let loopbackAddresses: [String]

	init(maximumSelections: Int, maximumRedirects: Int, bypassOrder: [String] = [],
		loopbackHosts: [String] = [], loopbackSuffixes: [String] = [],
		loopbackNetworks: [String] = [], loopbackAddresses: [String] = []) {
		self.maximumSelections = maximumSelections
		self.maximumRedirects = maximumRedirects
		self.bypassOrder = bypassOrder
		self.loopbackHosts = loopbackHosts
		self.loopbackSuffixes = loopbackSuffixes
		self.loopbackNetworks = loopbackNetworks
		self.loopbackAddresses = loopbackAddresses
	}

	static func parse(_ bytes: Data) -> ManagedBootstrapPolicy? {
		guard let fields = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
			ManagedBootstrapRequest.integer(fields["schema_version"]) == 1,
			let selections = ManagedBootstrapRequest.integer(fields["max_selections"]), selections > 0,
			selections <= 4096, let redirects = fields["redirects"] as? [String: Any],
			let hops = ManagedBootstrapRequest.integer(redirects["max_hops"]), hops <= Int64(Int32.max),
			fields["selected_proxy_bypass"] as? String == "environment",
			let order = inventory(fields["environment_bypass_precedence"]),
			let loopback = fields["loopback"] as? [String: Any],
			let hosts = inventory(loopback["dns_hosts"]), let suffixes = inventory(loopback["dns_suffixes"]),
			let networks = inventory(loopback["ipv4_cidrs"]), let addresses = inventory(loopback["ipv6_addresses"]),
			networks.allSatisfy({ ManagedBootstrapAddress.networkContains($0, host: "127.0.0.1") != nil
				&& ManagedBootstrapAddress.parse(String($0.split(separator: "/")[0]))?.family == AF_INET }),
			addresses.allSatisfy({ ManagedBootstrapAddress.parse($0)?.family == AF_INET6 })
		else { return nil }
		return ManagedBootstrapPolicy(maximumSelections: Int(selections), maximumRedirects: Int(hops),
			bypassOrder: order, loopbackHosts: hosts, loopbackSuffixes: suffixes,
			loopbackNetworks: networks, loopbackAddresses: addresses)
	}

	private static func inventory(_ value: Any?) -> [String]? {
		guard let strings = value as? [String], !strings.isEmpty, Set(strings).count == strings.count,
			strings.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) })
		else { return nil }
		return strings
	}

	func direct(_ url: URL, environment: [String: String]) -> Bool {
		guard var host = url.host?.lowercased() else { return false }
		while host.hasSuffix(".") { host.removeLast() }
		if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
		if loopbackHosts.contains(host) || loopbackSuffixes.contains(where: { host.count > $0.count && host.hasSuffix($0) }) { return true }
		if let address = ManagedBootstrapAddress.parse(host) {
			if loopbackAddresses.contains(where: { ManagedBootstrapAddress.parse($0) == address }) { return true }
			if loopbackNetworks.contains(where: { ManagedBootstrapAddress.networkContains($0, host: host) == true }) { return true }
		}
		let values = bypassOrder.compactMap { environment[$0] }.first { !$0.isEmpty } ?? ""
		let port = url.port ?? 443
		for raw in values.split(separator: ",", omittingEmptySubsequences: false) {
			let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if value == "*" { return true }
			if value.isEmpty { continue }
			if ManagedBootstrapAddress.networkContains(value, host: host) == true { return true }
			if let candidate = ManagedBootstrapAddress.parse(value), candidate == ManagedBootstrapAddress.parse(host) { return true }
			guard let parsed = URLComponents(string: value.contains("://") ? value : "http://" + value),
				parsed.user == nil, parsed.password == nil, var target = parsed.host?.lowercased(), !target.isEmpty,
				parsed.port == nil || parsed.port == port else { continue }
			while target.hasSuffix(".") { target.removeLast() }
			while target.hasPrefix("*") || target.hasPrefix(".") { target.removeFirst() }
			if target.hasPrefix("["), target.hasSuffix("]") { target = String(target.dropFirst().dropLast()) }
			if !target.isEmpty && (host == target || host.hasSuffix("." + target)) { return true }
		}
		return false
	}
}

private struct ManagedBootstrapAddress: Equatable {
	let family: Int32
	let bytes: [UInt8]

	static func parse(_ text: String) -> ManagedBootstrapAddress? {
		for (family, length) in [(AF_INET, 4), (AF_INET6, 16)] {
			var bytes = [UInt8](repeating: 0, count: length)
			let success = bytes.withUnsafeMutableBytes { buffer in inet_pton(family, text, buffer.baseAddress!) }
			if success == 1 { return ManagedBootstrapAddress(family: family, bytes: bytes) }
		}
		return nil
	}

	static func networkContains(_ text: String, host: String) -> Bool? {
		let parts = text.split(separator: "/", omittingEmptySubsequences: false)
		guard parts.count == 2, let network = parse(String(parts[0])), let prefix = Int(parts[1]),
			prefix >= 0, prefix <= network.bytes.count * 8 else { return nil }
		guard let address = parse(host), address.family == network.family else { return false }
		let whole = prefix / 8
		guard network.bytes.prefix(whole) == address.bytes.prefix(whole) else { return false }
		let bits = prefix % 8
		if bits == 0 { return true }
		let mask = UInt8.max << (8 - bits)
		return network.bytes[whole] & mask == address.bytes[whole] & mask
	}
}

/// A native executor emits complete bounded frames. This collector still checks
/// framing and terminal evidence; a cancelled session cannot masquerade as EOF.
final class ManagedBootstrapCollector {
	private let writeBody: (Data) -> Bool
	private let maximumBytes: Int64?
	private let remaining: () -> TimeInterval
	private(set) var status: Int?
	private(set) var location: String?
	private(set) var bytes: Int64 = 0
	private(set) var terminal = false
	private(set) var successfulTerminal = false
	private(set) var terminalReason: String?
	private(set) var failure: String?
	private(set) var redirectCancelled = false
	private var hash = SHA256()

	init(maximumBytes: Int64?, remaining: @escaping () -> TimeInterval,
		writeBody: @escaping (Data) -> Bool) {
		self.maximumBytes = maximumBytes
		self.remaining = remaining
		self.writeBody = writeBody
	}

	func consume(_ frame: Data) -> Bool {
		guard frame.count >= 5, frame.count <= ManagedHTTPFrame.maximumPayload + 4, !terminal else {
			failure = "protocol"; return false
		}
		let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
		guard Int(length) == frame.count - 4 else { failure = "protocol"; return false }
		let tag = frame[4]
		let payload = frame.subdata(in: 5..<frame.count)
		if tag == 67 { return consumeTerminal(payload) }
		guard remaining() > 0 else { failure = "deadline"; return false }
		guard failure == nil else { return false }
		if tag == 72 { return consumeHeaders(payload) }
		guard tag == 68, status == 200, !redirectCancelled,
			Int64(payload.count) <= Int64.max - bytes else { failure = "protocol"; return false }
		if let maximumBytes, Int64(payload.count) > maximumBytes - bytes {
			failure = "verify"; return false
		}
		guard writeBody(payload) else { failure = "file_write"; return false }
		hash.update(data: payload)
		bytes += Int64(payload.count)
		return true
	}

	private func consumeHeaders(_ payload: Data) -> Bool {
		guard status == nil,
			let fields = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
			Set(fields.keys) == Set(["version", "status", "headers"]),
			ManagedBootstrapRequest.integer(fields["version"]) == 1,
			let code = ManagedBootstrapRequest.integer(fields["status"]), (100...599).contains(code),
			let headers = fields["headers"] as? [[String]], headers.count <= 128
		else { failure = "protocol"; return false }
		for header in headers {
			guard header.count == 2, !header[0].isEmpty,
				!header[1].unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
			else { failure = "protocol"; return false }
			if header[0].lowercased() == "location" {
				guard location == nil, !header[1].isEmpty else { failure = "protocol"; return false }
				location = header[1]
			}
		}
		status = Int(code)
		if [301, 302, 303, 307, 308].contains(Int(code)) {
			guard location != nil else { failure = "http"; return false }
			// Refusing this exact header frame cancels its data task. The worker
			// publishes C only after the native session invalidation callback.
			redirectCancelled = true
			return false
		}
		guard code == 200 else { failure = "http"; return false }
		return true
	}

	private func consumeTerminal(_ payload: Data) -> Bool {
		guard let fields = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
			Set(fields.keys) == Set(["version", "success", "reason"]),
			ManagedBootstrapRequest.integer(fields["version"]) == 1,
			let success = fields["success"] as? NSNumber, CFGetTypeID(success) == CFBooleanGetTypeID(),
			let reason = fields["reason"] as? String,
			["complete", "protocol", "deadline", "cancelled", "offline", "certificate", "connect",
				"unavailable", "proxy", "content_encoding"].contains(reason)
		else { failure = "protocol"; return false }
		terminal = true
		successfulTerminal = success.boolValue
		terminalReason = reason
		return true
	}

	func verified(digest: String, size: Int64?) -> Bool {
		guard failure == nil, status == 200, terminal, successfulTerminal,
			terminalReason == "complete", remaining() > 0,
			size == nil || size == bytes else { return false }
		return hash.finalize().map { String(format: "%02x", $0) }.joined() == digest
	}
}

/// Keeps the descriptor and directory authority until verified publication.
/// Pathname cleanup is permitted only while it still names the owned inode.
final class ManagedBootstrapSpool {
	private let directory: Int32
	private let directoryPath: String
	private let directoryIdentity: stat
	private let descriptor: Int32
	private let name: String
	private let destination: String
	private let identity: stat
	private var published = false
	private var closed = false

	init?(output: String) {
		let parent = (output as NSString).deletingLastPathComponent
		let destination = (output as NSString).lastPathComponent
		guard !destination.isEmpty, destination != ".", destination != "..",
			let resolved = realpath(parent, nil) else { return nil }
		defer { free(resolved) }
		let directory = Darwin.open(resolved, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
		guard directory >= 0 else { return nil }
		var attributes = stat()
		guard fstat(directory, &attributes) == 0, attributes.st_uid == geteuid(),
			(attributes.st_mode & S_IFMT) == S_IFDIR,
			(attributes.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { Darwin.close(directory); return nil }
		let name = ".ergopti-bootstrap." + UUID().uuidString
		let descriptor = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
		guard descriptor >= 0 else { Darwin.close(directory); return nil }
		var identity = stat()
		guard fstat(descriptor, &identity) == 0, (identity.st_mode & S_IFMT) == S_IFREG else {
			Darwin.close(descriptor); Darwin.close(directory); return nil
		}
		self.directory = directory
		self.directoryPath = String(cString: resolved)
		self.directoryIdentity = attributes
		self.descriptor = descriptor
		self.identity = identity
		self.name = name
		self.destination = destination
	}

	func write(_ bytes: Data, remaining: () -> TimeInterval) -> Bool {
		var offset = 0
		while offset < bytes.count {
			guard remaining() > 0 else { return false }
			let count = bytes.withUnsafeBytes { buffer in
				Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
			}
			if count < 0 && errno == EINTR { continue }
			guard count > 0 else { return false }
			offset += count
		}
		return true
	}

	private func owns(_ candidate: String) -> Bool {
		var attributes = stat()
		return fstatat(directory, candidate, &attributes, AT_SYMLINK_NOFOLLOW) == 0
			&& (attributes.st_mode & S_IFMT) == S_IFREG
			&& attributes.st_dev == identity.st_dev && attributes.st_ino == identity.st_ino
	}

	private func directoryIsCurrent() -> Bool {
		var attributes = stat()
		return Darwin.lstat(directoryPath, &attributes) == 0 && (attributes.st_mode & S_IFMT) == S_IFDIR
			&& attributes.st_dev == directoryIdentity.st_dev && attributes.st_ino == directoryIdentity.st_ino
	}

	func verify(digest: String, bytes: Int64, remaining: () -> TimeInterval) -> Bool {
		var before = stat()
		guard !closed, remaining() > 0, directoryIsCurrent(), owns(name), fstat(descriptor, &before) == 0,
			before.st_size == bytes, Darwin.fsync(descriptor) == 0,
			lseek(descriptor, 0, SEEK_SET) == 0 else { return false }
		var hash = SHA256()
		var buffer = [UInt8](repeating: 0, count: 65_536)
		var copied: Int64 = 0
		while true {
			guard remaining() > 0 else { return false }
			let count = Darwin.read(descriptor, &buffer, buffer.count)
			if count < 0 && errno == EINTR { continue }
			guard count >= 0, Int64(count) <= bytes - copied else { return false }
			if count == 0 { break }
			hash.update(data: Data(buffer.prefix(count)))
			copied += Int64(count)
		}
		var after = stat()
		guard copied == bytes, remaining() > 0, owns(name), fstat(descriptor, &after) == 0,
			after.st_size == before.st_size, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
			after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
			after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
			after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
			after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { return false }
		return hash.finalize().map { String(format: "%02x", $0) }.joined() == digest
	}

	func publish(bytes: Int64, remaining: () -> TimeInterval) -> Bool {
		var attributes = stat()
		guard !closed, !published, remaining() > 0, directoryIsCurrent(), owns(name),
			fstat(descriptor, &attributes) == 0, attributes.st_size == bytes,
			Darwin.fsync(descriptor) == 0, remaining() > 0,
			linkat(directory, name, directory, destination, 0) == 0 else { return false }
		published = true
		guard owns(destination), Darwin.fsync(directory) == 0, directoryIsCurrent(), remaining() > 0 else { return false }
		return true
	}

	func close(success: Bool) -> Bool {
		guard !closed else { return false }
		var clean = !success || (published && owns(destination) && directoryIsCurrent())
		if (!success || !clean) && published {
			if owns(destination) { clean = unlinkat(directory, destination, 0) == 0 && clean }
			else { clean = false }
		}
		if owns(name) { clean = unlinkat(directory, name, 0) == 0 && clean }
		else { clean = false }
		clean = Darwin.fsync(directory) == 0 && clean
		clean = Darwin.close(descriptor) == 0 && clean
		clean = Darwin.close(directory) == 0 && clean
		closed = true
		return clean
	}
}

enum ManagedBootstrapDownload {
	static let flag = "--managed-bootstrap-download"
	static func handles(arguments: [String]) -> Bool { arguments.dropFirst().first == flag }

	static func execute(_ request: ManagedBootstrapRequest, policy: ManagedBootstrapPolicy,
		started: TimeInterval = ProcessInfo.processInfo.systemUptime,
		environment: [String: String] = ProcessInfo.processInfo.environment,
		settingsProvider: () -> CFDictionary? = { CFNetworkCopySystemProxySettings()?.takeRetainedValue() }) -> String {
		let budget = Double(request.timeoutMilliseconds) / 1000
		let remaining = { budget - (ProcessInfo.processInfo.systemUptime - started) }
		guard remaining() > 0 else { return "deadline" }
		guard let spool = ManagedBootstrapSpool(output: request.output) else { return "file_create" }
		var url = request.url
		var hops = 0
		var result = "unavailable"
		while remaining() > 0 {
			let collector = ManagedBootstrapCollector(maximumBytes: request.size, remaining: remaining,
				writeBody: { spool.write($0, remaining: remaining) })
			let native = ManagedHTTPRequest(url: url, method: "GET", headers: [("Accept-Encoding", "identity")],
				timeout: budget, idleTimeout: budget, direct: policy.direct(url, environment: environment))
			let status = ManagedHTTPWorker.execute(native, maximumSelections: policy.maximumSelections,
				started: started, settingsProvider: settingsProvider, output: collector.consume)
			guard remaining() > 0 else { result = "deadline"; break }
			if let failure = collector.failure { result = failure; break }
			if collector.redirectCancelled {
				guard status != 0, collector.terminal, !collector.successfulTerminal,
					collector.terminalReason == "protocol", collector.bytes == 0,
					hops < policy.maximumRedirects, let location = collector.location,
					let next = URL(string: location, relativeTo: url)?.absoluteURL,
					ManagedBootstrapRequest.acceptable(next) else { result = "http"; break }
				url = next
				hops += 1
				continue
			}
			guard status == 0, collector.verified(digest: request.sha256, size: request.size) else {
				result = collector.terminalReason == "complete" ? "verify" : (collector.terminalReason ?? "protocol")
				break
			}
			guard spool.verify(digest: request.sha256, bytes: collector.bytes, remaining: remaining) else {
				result = "verify"; break
			}
			result = spool.publish(bytes: collector.bytes, remaining: remaining) ? "complete" : "file_publish"
			break
		}
		if remaining() <= 0 { result = "deadline" }
		return spool.close(success: result == "complete") ? result : "cleanup"
	}

	static func run(arguments: [String]) -> Int32 {
		let started = ProcessInfo.processInfo.systemUptime
		guard arguments.count == 3, let milliseconds = Int(arguments[2]),
			milliseconds > 0, milliseconds <= Int(Int32.max) else { return 64 }
		let budget = Double(milliseconds) / 1000
		var input = Data()
		var buffer = [UInt8](repeating: 0, count: 4096)
		while true {
			let remaining = budget - (ProcessInfo.processInfo.systemUptime - started)
			guard remaining > 0 else { return report("deadline") }
			var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
			let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, Double(Int32.max))))
			if ready < 0 && errno == EINTR { continue }
			guard ready >= 0 else { return report("protocol") }
			if ready == 0 { continue }
			let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
			if count < 0 && errno == EINTR { continue }
			guard count >= 0, count <= 65_536 - input.count else { return report("protocol") }
			if count == 0 { break }
			input.append(contentsOf: buffer.prefix(count))
		}
		guard let request = ManagedBootstrapRequest.parse(input), request.timeoutMilliseconds == milliseconds else { return 64 }
		let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/static/ergopti_plus/_shared/modules/network/proxy_policy.json")
		guard let bytes = try? Data(contentsOf: path), let policy = ManagedBootstrapPolicy.parse(bytes) else { return report("unavailable") }
		return report(execute(request, policy: policy, started: started))
	}

	private static func report(_ reason: String) -> Int32 {
		guard let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "success": reason == "complete", "reason": reason]) else { return 74 }
		FileHandle.standardOutput.write(data)
		FileHandle.standardOutput.write(Data([10]))
		return reason == "complete" ? 0 : (reason == "deadline" ? 75 : 74)
	}
}
