// Sources/ErgoptiPlus/OwnedRuntimeServiceReferenceWorker.swift
// Read-only same-executing-principal source custody; no service or installation authority.
import Darwin
import Foundation

/// Closed headless observations never mint code, consent or runtime lifecycle authority.
enum OwnedRuntimeServiceReferenceWorker {
	static let role = "--owned-runtime-service-reference"
	private enum Completion: String { case command, eof, input, deadline, changed, unavailable, output }

	static func handles(arguments: [String]) -> Bool {
		arguments.count > 1 && arguments[1] == role
	}

	// Borrowed flags belong to the caller and must remain nonblocking for this role.
	private static func nonblockingInput() -> Bool {
		let flags = fcntl(STDIN_FILENO, F_GETFL)
		return flags >= 0 && flags & O_NONBLOCK != 0
	}

	private static func write(_ line: String) -> Bool {
		do { try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8)); return true }
		catch { return false }
	}

	private static func settle(_ owner: OwnedRuntimeServiceReferenceOwner, reason: Completion, status: Int32) -> Int32 {
		guard owner.retire(), owner.retired() else {
			_ = write("V1 RETIRE_REFUSED")
			return 70
		}
		return write("V1 RETIRED " + reason.rawValue) ? status : 74
	}

	static func run(arguments: [String]) -> Int32 {
		guard arguments.count == 2, arguments[1] == role else { return 64 }
		guard nonblockingInput() else { return 64 }
		_ = Darwin.signal(SIGPIPE, SIG_IGN)
		let deadline = ProcessInfo.processInfo.systemUptime + 25
		let owner = OwnedRuntimeServiceReferenceOwner.acquire()
		defer { _ = owner.retire() }
		guard let token = owner.identity(), owner.current(token) else {
			let reason: String
			switch owner.refusal() {
			case .launcherPrincipalUnavailable?: reason = "principal"
			case .policyRefused?: reason = "policy"
			case .signatureRefused?: reason = "signature"
			default: reason = "source"
			}
			guard write("V1 REFUSED " + reason) else { return settle(owner, reason: .output, status: 74) }
			return settle(owner, reason: .unavailable, status: 69)
		}
		guard ProcessInfo.processInfo.systemUptime < deadline else { return settle(owner, reason: .deadline, status: 75) }
		guard write("V1 HELD") else { return settle(owner, reason: .output, status: 74) }
		var line = Data(), commands = 0
		while commands < 8 {
			let remaining = deadline - ProcessInfo.processInfo.systemUptime
			guard remaining > 0 else { return settle(owner, reason: .deadline, status: 75) }
			var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
			let ready = Darwin.poll(&input, 1, Int32(min(remaining * 1000, 100)))
			if ready < 0 && errno == EINTR { continue }
			guard ready >= 0 else { return settle(owner, reason: .input, status: 64) }
			if ready == 0 { continue }
			guard nonblockingInput() else { return settle(owner, reason: .input, status: 64) }
			var byte: UInt8 = 0
			let count = Darwin.read(STDIN_FILENO, &byte, 1)
			if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
			if count == 0 {
				return line.isEmpty ? settle(owner, reason: .eof, status: 0) : settle(owner, reason: .input, status: 64)
			}
			guard count == 1 else { return settle(owner, reason: .input, status: 64) }
			if byte == 10 {
				commands += 1
				guard let command = String(data: line, encoding: .ascii) else { return settle(owner, reason: .input, status: 64) }
				line.removeAll(keepingCapacity: true)
				switch command {
				case "CURRENT":
					let current = owner.current(token)
					guard write(current ? "V1 CURRENT 1" : "V1 CURRENT 0") else { return settle(owner, reason: .output, status: 74) }
					if !current { return settle(owner, reason: .changed, status: 76) }
				case "RETIRE": return settle(owner, reason: .command, status: 0)
				default: return settle(owner, reason: .input, status: 64)
				}
			} else {
				guard line.count < 7, byte >= 65, byte <= 90 else { return settle(owner, reason: .input, status: 64) }
				line.append(byte)
			}
		}
		return settle(owner, reason: .input, status: 64)
	}
}
