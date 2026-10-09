// tests/support/native_http_fixture_main.swift
// Test-only callee for real client receiving; never part of the release target.

import CFNetwork
import CoreFoundation
import Darwin
import Foundation
import Security

// This diagnostic reads the exact owned certificate; certificate enumeration in
// the admin domain can omit private-keychain certificates. Only a validated
// external trust-list cardinality and the direct certificate lookup are emitted.
private func fixtureAdminTrustQuery() -> Int32 {
	var bytes = Data()
	var buffer = [UInt8](repeating: 0, count: 4096)
	while true {
		let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
		if count < 0 && errno == EINTR { continue }
		guard count >= 0 else { return 74 }
		if count == 0 { break }
		guard count <= 16_384 - bytes.count else { return 64 }
		bytes.append(contentsOf: buffer.prefix(count))
	}
	guard !bytes.isEmpty, let certificate = SecCertificateCreateWithData(nil, bytes as CFData) else { return 64 }
	var ownedSettings: CFArray?
	let ownedStatus = SecTrustSettingsCopyTrustSettings(certificate, .admin, &ownedSettings)
	let ownedPresent: Any
	if ownedStatus == errSecSuccess, ownedSettings != nil { ownedPresent = 1 }
	else if ownedStatus == errSecItemNotFound || ownedStatus == errSecNoTrustSettings { ownedPresent = 0 }
	else { ownedPresent = NSNull() }
	var external: CFData?
	let exportStatus = SecTrustSettingsCreateExternalRepresentation(.admin, &external)
	var entryCount: Any = NSNull()
	if exportStatus == errSecNoTrustSettings { entryCount = 0 }
	else if exportStatus == errSecSuccess, let external, CFDataGetLength(external) <= 1_048_576,
		let fields = try? PropertyListSerialization.propertyList(from: external as Data, options: [], format: nil) as? [String: Any],
		Set(fields.keys) == Set(["trustVersion", "trustList"]),
		let version = fields["trustVersion"] as? NSNumber,
		CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
		let entries = fields["trustList"] as? [String: Any], entries.count <= 65_535,
		entries.allSatisfy({ key, value in
			key.utf8.count == 40 && key.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
				&& value is [String: Any]
		}) { entryCount = entries.count }
	let fact: [String: Any] = ["version": 1, "export_status": exportStatus, "entry_count": entryCount,
		"owned_status": ownedStatus, "owned_present": ownedPresent]
	guard let output = try? JSONSerialization.data(withJSONObject: fact, options: [.sortedKeys]) else { return 74 }
	var offset = 0
	while offset < output.count {
		let count = output.withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress!.advanced(by: offset), output.count - offset) }
		if count < 0 && errno == EINTR { continue }
		guard count > 0 else { return 74 }
		offset += count
	}
	return 0
}


// Fixed lexical stages use a separate private file. stdout remains exclusively
// the unchanged response ABI. A missing/refused observation cannot change its
// request verdict or authorize a native operation.
private final class FixtureStages {
	private var descriptor: Int32 = -1
	private var seen = Set<String>()
	private let lock = NSLock()

	init(executable: String) {
		let path = URL(fileURLWithPath: executable).deletingLastPathComponent()
			.deletingLastPathComponent().appendingPathComponent("Resources/fixture-worker-stages").path
		let opened = Darwin.open(path, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
		guard opened >= 0 else { return }
		var identity = stat()
		guard fstat(opened, &identity) == 0, (identity.st_mode & S_IFMT) == S_IFREG,
			identity.st_uid == getuid(), identity.st_nlink == 1,
			(identity.st_mode & 0o777) == 0o600, identity.st_size == 0 else {
			Darwin.close(opened); return
		}
		descriptor = opened
	}

	deinit { if descriptor >= 0 { Darwin.close(descriptor) } }

	func mark(_ stage: String) {
		// Contention refuses only this observation; it cannot block a request.
		guard lock.try() else { return }
		defer { lock.unlock() }
		guard descriptor >= 0, seen.insert(stage).inserted else { return }
		let bytes = Array((stage + "\n").utf8)
		let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
		if count != bytes.count { Darwin.close(descriptor); descriptor = -1 }
	}
}

// This symbol exists only in the separately compiled fixture. Release builds
// never define its compilation condition or include this test-only entrypoint.
private enum FixtureHTTPObservation {
	nonisolated(unsafe) static var owner: FixtureStages?
}

func managedHTTPFixtureStage(_ stage: String) {
	FixtureHTTPObservation.owner?.mark(stage)
}

// The private fixture App binds fixed native settings beside its exact source
// and signed binary. Production has no settings-file/environment override.
func fixtureMain() -> Int32 {
	let arguments = CommandLine.arguments
	if arguments.count == 2, arguments[1] == "--fixture-admin-trust-query" { return fixtureAdminTrustQuery() }
	let stages = FixtureStages(executable: arguments[0])
	FixtureHTTPObservation.owner = stages
	defer { FixtureHTTPObservation.owner = nil }
	stages.mark("entry")
	guard arguments.count == 4, arguments[1] == "--managed-http-worker",
		let idle = Double(arguments[2]), idle.isFinite, idle > 0 else { return 64 }
	let budget: TimeInterval?
	if arguments[3] == "none" { budget = nil }
	else if let parsed = Double(arguments[3]), parsed.isFinite, parsed > 0 { budget = parsed }
	else { return 64 }
	stages.mark("arguments")
	let started = ProcessInfo.processInfo.systemUptime
	let parent = getppid()
	_ = Darwin.signal(SIGPIPE, SIG_IGN)
	let watchdog = DispatchSource.makeTimerSource(queue: .global())
	watchdog.schedule(deadline: .now(), repeating: .milliseconds(20))
	watchdog.setEventHandler {
		if getppid() != parent { Darwin._exit(74) }
		if let budget, ProcessInfo.processInfo.systemUptime - started >= budget { Darwin._exit(75) }
	}
	watchdog.resume()
	defer { watchdog.cancel() }
	var bytes = Data()
	var buffer = [UInt8](repeating: 0, count: 4096)
	while true {
		let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
		if count < 0 && errno == EINTR { continue }
		guard count >= 0 else { return 74 }
		if count == 0 { break }
		guard count <= 65_536 - bytes.count else { return 64 }
		bytes.append(contentsOf: buffer.prefix(count))
	}
	stages.mark("stdin_eof")
	guard let request = ManagedHTTPRequest.parse(bytes), request.timeout == budget,
		request.idleTimeout <= idle else { return 64 }
	stages.mark("request")
	let privateSettings = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent()
		.deletingLastPathComponent().appendingPathComponent("Resources/fixture-proxy-settings.json")
	guard let settingsBytes = try? Data(contentsOf: privateSettings),
		let settings = try? JSONSerialization.jsonObject(with: settingsBytes) as? [String: Any] else { return 78 }
	stages.mark("settings")
	let policy = privateSettings.deletingLastPathComponent()
		.appendingPathComponent("static/ergopti_plus/_shared/modules/network/proxy_policy.json")
	guard let policyBytes = try? Data(contentsOf: policy),
		let policyFields = try? JSONSerialization.jsonObject(with: policyBytes) as? [String: Any],
		let maximum = policyFields["max_selections"] as? NSNumber,
		CFGetTypeID(maximum) != CFBooleanGetTypeID(), maximum.doubleValue == Double(maximum.intValue), maximum.intValue > 0
	else { return 78 }
	stages.mark("policy")
	stages.mark("execute")
	let status = ManagedHTTPWorker.execute(request, maximumSelections: maximum.intValue, started: started,
		settingsProvider: { stages.mark("settings_provider"); return settings as CFDictionary }, output: { frame in
			stages.mark("first_frame")
			var offset = 0
			while offset < frame.count {
				let count = frame.withUnsafeBytes { pointer in
					Darwin.write(STDOUT_FILENO, pointer.baseAddress!.advanced(by: offset), frame.count - offset)
				}
				if count < 0 && errno == EINTR { continue }
				guard count > 0 else { Darwin._exit(74) }
				offset += count
			}
			return true
		})
	stages.mark("returned")
	return status
}

// @main avoids top-level source behavior in a multi-file swiftc invocation.
@main
struct ManagedHTTPFixtureMain {
	static func main() { Darwin.exit(fixtureMain()) }
}
