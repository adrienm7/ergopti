// Sources/ErgoptiPlus/OwnedAutomationQueryWorker.swift
// Signed bounded read-only Shortcuts query with exact native group retirement.

import CPOSIXCompatibility
import Carbon
import CoreFoundation
import Darwin
import Foundation
import ScriptingBridge

private let automationQueryFlag = "--automation-query-worker"
private let automationRoleFlag = "--automation-query-role"
private let automationMaximumBytes = 65536

/// Errors stay private; native permission codes never become successful empty lists.
private final class AutomationQueryErrors: NSObject, SBApplicationDelegate {
	var failure: String?
	func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: Error) -> Any? {
		failure = (error as NSError).code == -1743 ? "automation_permission_refused" : "native_refused"
		return nil
	}
}

/// Static roles run only from the shipped signed launcher, never a user script.
enum OwnedAutomationQueryWorker {
	static func handles(arguments: [String]) -> Bool {
		return arguments.count > 1 && [automationQueryFlag, automationRoleFlag].contains(arguments[1])
	}

	static func validIdentifier(_ value: String) -> Bool {
		return value.utf8.count == 36 && UUID(uuidString: value) != nil
	}

	static func validRequest(arguments: [String]) -> Bool {
		guard arguments.count >= 4, let nonce = Int64(arguments[3]), nonce > 0,
			nonce <= 9007199254740991, String(nonce) == arguments[3] else { return false }
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		if ["fixture", "fixture-overflow", "fixture-stderr", "fixture-wait"].contains(arguments[2]) {
			return arguments.count == 4
		}
		#endif
		return arguments[2] == "discover" && arguments.count == 4
			|| arguments[2] == "revalidate" && arguments.count == 5 && validIdentifier(arguments[4])
	}

	private static func write(_ bytes: Data) -> Bool {
		var offset = 0
		while offset < bytes.count {
			let count = bytes.withUnsafeBytes { buffer in
				Darwin.write(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
			}
			if count > 0 { offset += count }
			else if count < 0 && errno == EINTR { continue }
			else { return false }
		}
		return true
	}

	private static func marker(_ value: String) -> Bool { return write(Data((value + "\n").utf8)) }

	private static func nonblocking(_ descriptor: Int32) -> Bool {
		let flags = fcntl(descriptor, F_GETFL)
		return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
	}

	private static func makePipe() -> [Int32]? {
		var descriptors: [Int32] = [-1, -1]
		guard pipe(&descriptors) == 0 else { return nil }
		guard descriptors.allSatisfy({ fcntl($0, F_SETFD, FD_CLOEXEC) == 0 }),
			nonblocking(descriptors[0]) else {
			for descriptor in descriptors { Darwin.close(descriptor) }
			return nil
		}
		return descriptors
	}

	/// Native group custody is retained until the C owner's acknowledged destruction.
	static func run(arguments: [String]) -> Int32 {
		guard validRequest(arguments: arguments) else { return 64 }
		_ = Darwin.signal(SIGPIPE, SIG_IGN)
		if arguments[1] == automationRoleFlag { return queryRole(arguments: arguments) }
		guard arguments[1] == automationQueryFlag else { return 64 }
		// Hammerspoon cancels by EOF. Signals cannot interrupt a live custody frame.
		_ = Darwin.signal(SIGTERM, SIG_IGN)
		_ = Darwin.signal(SIGINT, SIG_IGN)
		guard (getsid(0) == getpid() || setsid() == getpid()), nonblocking(STDIN_FILENO) else {
			return marker("Q1 REFUSED \(errno == 0 ? EIO : errno)") ? 0 : 74
		}
		prepareLeaseChildReaping()
		guard let output = makePipe() else { return marker("Q1 REFUSED \(EIO)") ? 0 : 74 }
		defer { Darwin.close(output[0]) }
		guard let errors = makePipe() else {
			Darwin.close(output[1]); return marker("Q1 REFUSED \(EIO)") ? 0 : 74
		}
		defer { Darwin.close(errors[0]) }
		let executable = arguments[0]
		guard let expected = LeaseExecutableIdentity.capture(at: executable),
			let argv = duplicateCStringVector([executable, automationRoleFlag] + Array(arguments.dropFirst(2))) else {
			Darwin.close(output[1]); Darwin.close(errors[1])
			return marker("Q1 REFUSED \(ESTALE)") ? 0 : 74
		}
		guard let envp = duplicateProcessEnvironment() else {
			for case let pointer? in argv { free(pointer) }
			Darwin.close(output[1]); Darwin.close(errors[1])
			return marker("Q1 REFUSED \(ENOMEM)") ? 0 : 74
		}
		defer {
			for case let pointer? in argv { free(pointer) }
			for case let pointer? in envp { free(pointer) }
		}
		var mutableArguments = argv, mutableEnvironment = envp
		var owner: OpaquePointer?
		let prepared = mutableArguments.withUnsafeMutableBufferPointer { arguments in
			mutableEnvironment.withUnsafeMutableBufferPointer { environment in
				ergopti_owned_query_prepare(executable, arguments.baseAddress, environment.baseAddress,
					output[1], errors[1], &owner)
			}
		}
		Darwin.close(output[1]); Darwin.close(errors[1])
		guard owner != nil else { return marker("Q1 REFUSED \(prepared == 0 ? EPROTO : prepared)") ? 0 : 74 }
		var cancelled = prepared != 0 || LeaseExecutableIdentity.capture(at: executable) != expected
		var activated = false, pendingSent = false, outputEOF = false, errorEOF = false
		var payload = Data(), control = OwnedProgramLineDecoder(maximumBytes: 32)
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		if !cancelled && !marker("Q1 HELD") { cancelled = true }
		func drain(_ descriptor: Int32, into buffer: inout Data, eof: inout Bool, maximum: Int, afterRetirement: Bool = false) -> Bool {
			if eof { return true }
			var bytes = [UInt8](repeating: 0, count: 4096)
			let count = Darwin.read(descriptor, &bytes, bytes.count)
			if count == 0 { eof = true; return true }
			if count < 0 { return !afterRetirement && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) }
			guard count <= maximum - buffer.count else { return false }
			buffer.append(contentsOf: bytes.prefix(count))
			return true
		}
		var discardedErrors = Data()
		while let retained = owner {
			var input = [UInt8](repeating: 0, count: 64)
			let count = Darwin.read(STDIN_FILENO, &input, input.count)
			if count == 0 { cancelled = true }
			else if count > 0 {
				if !control.append(Data(input.prefix(count))) { cancelled = true }
				while let line = control.pop() {
					if line == Data("ACTIVATE".utf8), !activated, !cancelled {
						let receipt = ergopti_owned_program_activate(retained)
						activated = receipt.active && !receipt.cancelled
						if !activated { cancelled = true }
					} else { cancelled = true }
				}
			} else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { cancelled = true }
			if !drain(output[0], into: &payload, eof: &outputEOF, maximum: automationMaximumBytes)
				|| !drain(errors[0], into: &discardedErrors, eof: &errorEOF, maximum: 0)
				|| ProcessInfo.processInfo.systemUptime >= deadline { cancelled = true }
			if cancelled { _ = ergopti_owned_program_cancel(retained) }
			let receipt = ergopti_owned_program_poll(retained)
			if receipt.retired {
				guard receipt.status_valid, receipt.error_code == 0,
					ergopti_owned_program_destroy(&owner) else { return 70 }
				// Drain remaining finite pipe bytes after every inherited writer retired.
				while !outputEOF {
					if !drain(output[0], into: &payload, eof: &outputEOF, maximum: automationMaximumBytes, afterRetirement: true) {
						cancelled = true; break
					}
				}
				while !errorEOF {
					if !drain(errors[0], into: &discardedErrors, eof: &errorEOF, maximum: 0, afterRetirement: true) {
						cancelled = true; break
					}
				}
				if activated && !cancelled && receipt.exit_status == 0 && !payload.isEmpty {
					guard marker("Q1 DATA " + payload.base64EncodedString()) else { return 74 }
				}
				return marker("Q1 RETIRED \(receipt.exit_status)") ? 0 : 74
			}
			if (cancelled || receipt.error_code != 0) && !pendingSent {
				pendingSent = true
				if !marker("Q1 PENDING \(receipt.error_code)") { cancelled = true }
			}
			var event = pollfd(fd: outputEOF ? -1 : output[0], events: Int16(POLLIN), revents: 0)
			_ = Darwin.poll(&event, 1, 20)
		}
		return 70
	}

	/// Read-only AppleEvents stay isolated from the interactive Hammerspoon runloop.
	private static func queryRole(arguments: [String]) -> Int32 {
		let operation = arguments[2], nonce = Int64(arguments[3])!
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		// Fixed owned native fixtures never issue AppleEvents or run user input.
		if operation == "fixture-overflow" { return write(Data(repeating: 65, count: 65537)) ? 0 : 74 }
		if operation == "fixture-stderr" {
			let sentinel = Array("PRIVATE_NATIVE_QUERY_ERROR".utf8)
			_ = sentinel.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, sentinel.count) }
			return 0
		}
		if operation == "fixture-wait" { usleep(30_000_000); return 0 }
		if operation == "fixture" {
			let packet: [String: Any] = ["version": 1, "nonce": nonce, "operation": "discover", "status": "observed",
				"rows": [["id": "11111111-1111-1111-1111-111111111111", "name": "日本 e\u{301}\n", "accepts_input": false]],
				"truncated": false]
			return write(try! JSONSerialization.data(withJSONObject: packet)) ? 0 : 74
		}
		#endif
		let observer = AutomationQueryErrors()
		func refusal(_ reason: String) -> [String: Any] {
			return ["version": 1, "operation": operation, "nonce": nonce, "status": "refused", "reason": reason]
		}
		func publish(_ packet: [String: Any]) -> Int32 {
			guard let bytes = try? JSONSerialization.data(withJSONObject: packet),
				bytes.count <= automationMaximumBytes else {
				let bytes = try! JSONSerialization.data(withJSONObject: refusal("native_refused"))
				return write(bytes) ? 0 : 74
			}
			return write(bytes) ? 0 : 74
		}
		// Ask only whether existing consent permits the readonly request. Discovery
		// must not open a TCC prompt or silently grant automation permission.
		var target = AEAddressDesc()
		let address = Array("com.apple.shortcuts.events".utf8)
		let addressError = address.withUnsafeBytes { bytes in
			AECreateDesc(typeApplicationBundleID, bytes.baseAddress, address.count, &target)
		}
		guard addressError == noErr else { return publish(refusal("native_refused")) }
		defer { AEDisposeDesc(&target) }
		let permission = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
		guard permission == noErr else {
			return publish(refusal(permission == -1743 || permission == -1744
				? "automation_permission_refused" : "native_refused"))
		}
		guard let app = SBApplication(bundleIdentifier: "com.apple.shortcuts.events") else {
			return publish(refusal("native_refused"))
		}
		app.delegate = observer
		app.timeout = 600
		guard let catalogue = app.value(forKey: "shortcuts") as? SBElementArray else {
			return publish(refusal(observer.failure ?? "native_refused"))
		}
		func row(_ object: Any) -> [String: Any]? {
			guard let object = object as? SBObject,
				let id = object.value(forKey: "id") as? String, validIdentifier(id),
				let name = object.value(forKey: "name") as? String, !name.utf8.contains(0), name.utf8.count <= 4096,
				let accepts = object.value(forKey: "acceptsInput") as? NSNumber,
				CFGetTypeID(accepts) == CFBooleanGetTypeID(), observer.failure == nil else { return nil }
			return ["id": id, "name": name, "accepts_input": accepts.boolValue]
		}
		var rows: [[String: Any]] = [], truncated = false
		if operation == "discover" {
			let count = catalogue.count
			if let failure = observer.failure { return publish(refusal(failure)) }
			guard count <= 256 else { return publish(refusal("catalogue_limit")) }
			var ids = Set<String>()
			for index in 0..<min(count, 64) {
				guard let value = row(catalogue.object(at: index)), let id = value["id"] as? String,
					ids.insert(id).inserted else { return publish(refusal(observer.failure ?? "native_refused")) }
				rows.append(value)
			}
			guard catalogue.count == count, observer.failure == nil else {
				return publish(refusal(observer.failure ?? "native_refused"))
			}
			truncated = count > 64
		} else {
			let identifier = arguments[4]
			guard let chosen = row(catalogue.object(withID: identifier)), chosen["id"] as? String == identifier,
				let after = row(catalogue.object(withID: identifier)), NSDictionary(dictionary: chosen).isEqual(to: after)
			else { return publish(refusal(observer.failure ?? "missing")) }
			rows = [chosen]
		}
		return publish(["version": 1, "operation": operation, "nonce": nonce,
			"status": "observed", "rows": rows, "truncated": truncated])
	}
}
