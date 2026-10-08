// tests/support/native_http_fixture_main.swift
// Test-only callee for real client receiving; never part of the release target.

import CFNetwork
import CoreFoundation
import Darwin
import Foundation

// The private fixture App binds fixed native settings beside its exact source
// and signed binary. Production has no settings-file/environment override.
func fixtureMain() -> Int32 {
	let arguments = CommandLine.arguments
	guard arguments.count == 4, arguments[1] == "--managed-http-worker",
		let idle = Double(arguments[2]), idle.isFinite, idle > 0 else { return 64 }
	let budget: TimeInterval?
	if arguments[3] == "none" { budget = nil }
	else if let parsed = Double(arguments[3]), parsed.isFinite, parsed > 0 { budget = parsed }
	else { return 64 }
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
	guard let request = ManagedHTTPRequest.parse(bytes), request.timeout == budget,
		request.idleTimeout <= idle else { return 64 }
	let privateSettings = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent()
		.deletingLastPathComponent().appendingPathComponent("Resources/fixture-proxy-settings.json")
	guard let settingsBytes = try? Data(contentsOf: privateSettings),
		let settings = try? JSONSerialization.jsonObject(with: settingsBytes) as? [String: Any] else { return 78 }
	let policy = privateSettings.deletingLastPathComponent()
		.appendingPathComponent("static/ergopti_plus/_shared/modules/network/proxy_policy.json")
	guard let policyBytes = try? Data(contentsOf: policy),
		let policyFields = try? JSONSerialization.jsonObject(with: policyBytes) as? [String: Any],
		let maximum = policyFields["max_selections"] as? NSNumber,
		CFGetTypeID(maximum) != CFBooleanGetTypeID(), maximum.doubleValue == Double(maximum.intValue), maximum.intValue > 0
	else { return 78 }
	return ManagedHTTPWorker.execute(request, maximumSelections: maximum.intValue, started: started,
		settingsProvider: { settings as CFDictionary }, output: { frame in
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
}

// @main avoids top-level source behavior in a multi-file swiftc invocation.
@main
struct ManagedHTTPFixtureMain {
	static func main() { Darwin.exit(fixtureMain()) }
}
