// Sources/ErgoptiPlus/InstalledPhysicalSourceBridge.swift
// Fixed installed capture transport; publication never creates coverage authority.

import CPOSIXCompatibility
import Darwin
import Dispatch
import Foundation
import CoreFoundation

/// Runs in the signed launcher before any GUI or Hammerspoon startup.
/// The original CLI owns its authenticated Core socket and capture protocol.
enum InstalledPhysicalSourceBridge {
	static let role = "--installed-physical-source"
	private static let maximumPendingBytes = 65536

	private final class RefusedCustody {
		let program: OpaquePointer
		let peer: OwnedRuntimeInstalledPeerOwner
		let image: OwnedRuntimeInstalledPeerOwner.CLIImageLease
		let console: OwnedRuntimeUserConsoleOwner
		let descriptors: [Int32]
		init(program: OpaquePointer, peer: OwnedRuntimeInstalledPeerOwner,
			image: OwnedRuntimeInstalledPeerOwner.CLIImageLease,
			console: OwnedRuntimeUserConsoleOwner, descriptors: [Int32]) {
			self.program = program; self.peer = peer; self.image = image
			self.console = console; self.descriptors = descriptors
		}
	}
	private static let debtLock = NSLock()
	private static var refusedCustody: [RefusedCustody] = []

	private final class TerminalObservation {
		private var bytes = Data()
		private var preparation: [String: Any]?
		private(set) var retired = false
		private func decimal(_ value: Any?) -> Bool {
			guard let text = value as? String, !text.isEmpty, text.first != "0",
				text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), UInt64(text) != nil else { return false }
			return true
		}
		func consume(_ block: Data) -> Bool {
			guard block.count <= maximumPendingBytes - bytes.count else { return false }
			bytes.append(block)
			while let end = bytes.firstIndex(of: 10) {
				let line = bytes.prefix(upTo: end)
				guard !line.isEmpty, let object = try? JSONSerialization.jsonObject(with: Data(line)),
					let fields = object as? [String: Any], let kind = fields["kind"] as? String else { return false }
				bytes.removeSubrange(...end)
				if retired { return false }
				if kind == "prepared" || kind == "cohort_retired" || kind == "cohort_retirement_refused" {
					guard let version = fields["version"] as? NSNumber,
						CFGetTypeID(version) != CFBooleanGetTypeID(), version.stringValue == "1",
						let incarnation = fields["incarnation"] as? String, !incarnation.isEmpty,
						decimal(fields["preparation"]) else { return false }
					if kind == "prepared" {
						guard preparation == nil, Set(fields.keys) == Set(["version","kind","coverage","incarnation","preparation"]),
							(fields["coverage"] as? String) == "pending" else { return false }
						preparation = fields
					} else {
						guard kind == "cohort_retired", let preparation,
							Set(fields.keys) == Set(["version","kind","incarnation","preparation","cohort"]),
							(fields["incarnation"] as? String) == (preparation["incarnation"] as? String),
							(fields["preparation"] as? String) == (preparation["preparation"] as? String),
							decimal(fields["cohort"]) else { return false }
						retired = true
					}
				}
			}
			return true
		}
		func ended() -> Bool { return bytes.isEmpty && retired }
	}

	static func handles(arguments: [String]) -> Bool {
		return arguments.count == 2 && arguments[1] == role
	}

	private static func pipePair(closeRefused: inout Bool) -> [Int32]? {
		var descriptors: [Int32] = [-1, -1]
		guard pipe(&descriptors) == 0 else { return nil }
		for descriptor in descriptors {
			guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
				for retained in descriptors { if Darwin.close(retained) != 0 { closeRefused = true } }
				return nil
			}
		}
		return descriptors
	}

	private static func nonblocking(_ descriptor: Int32) -> Bool {
		let flags = fcntl(descriptor, F_GETFL)
		return flags >= 0 && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
	}

	/// No caller executable, arguments, descriptor or authority options are accepted.
	static func run() -> Int32 {
		var pipeCloseRefused = false
		func closePipe(_ descriptor: Int32) {
			if Darwin.close(descriptor) != 0 { pipeCloseRefused = true }
		}
		guard let peer = OwnedRuntimeInstalledPeerOwner.acquire() else { return 77 }
		guard let image = peer.acquireCLIImage() else {
			peer.requestRetirement()
			return peer.retired() ? 77 : 70
		}
		guard ergopti_owned_program_create_private_session() == 0,
			peer.current(), image.current(), let console = OwnedRuntimeUserConsoleOwner.acquire(peer: peer) else {
			image.requestRetirement()
			guard image.retired() else { return 70 }
			peer.requestRetirement()
			return peer.retired() ? 77 : 70
		}
		let stopLock = NSLock()
		var stopRequested = false
		let stopQueue = DispatchQueue(label: "com.ergoptiplus.installed-source.stop")
		var stopSources: [DispatchSourceSignal] = []
		for number in [SIGTERM, SIGINT] {
			_ = Darwin.signal(number, SIG_IGN)
			let source = DispatchSource.makeSignalSource(signal: number, queue: stopQueue)
			source.setEventHandler {
				stopLock.lock(); stopRequested = true; stopLock.unlock()
			}
			source.resume(); stopSources.append(source)
		}
		defer { for source in stopSources { source.cancel() } }
		func stopping() -> Bool {
			stopLock.lock(); defer { stopLock.unlock() }
			return stopRequested
		}
		// Every return after this point explicitly settles the native image lease.
		func settleImage() -> Bool {
			console.requestRetirement()
			while !console.retired() {
				// Refusal keeps the Console owner's exact native debt; never convert it to ACK.
				if console.failure() != nil { return false }
				_ = Darwin.poll(nil, 0, 25)
			}
			guard !pipeCloseRefused else { return false }
			image.requestRetirement()
			guard image.retired() else { return false }
			peer.requestRetirement()
			return peer.retired()
		}
		guard peer.current(), image.current() else { return settleImage() ? 77 : 70 }
		guard let input = pipePair(closeRefused: &pipeCloseRefused) else { return settleImage() ? 74 : 70 }
		guard let output = pipePair(closeRefused: &pipeCloseRefused) else {
			for descriptor in input { closePipe(descriptor) }
			return settleImage() ? 74 : 70
		}
		guard let errors = pipePair(closeRefused: &pipeCloseRefused) else {
			for descriptor in input + output { closePipe(descriptor) }
			return settleImage() ? 74 : 70
		}
		guard let argv = duplicateCStringVector([image.executablePath, "--installed-physical-capture", "25"]) else {
			for descriptor in input + output + errors { closePipe(descriptor) }
			return settleImage() ? 74 : 70
		}
		guard let envp = duplicateProcessEnvironment() else {
			for case let pointer? in argv { free(pointer) }
			for descriptor in input + output + errors { closePipe(descriptor) }
			return settleImage() ? 74 : 70
		}
		defer {
			for case let pointer? in argv { free(pointer) }
			for case let pointer? in envp { free(pointer) }
		}
		guard console.requestStart() else {
			for descriptor in input + output + errors { closePipe(descriptor) }
			return settleImage() ? 77 : 70
		}
		var mutableArguments = argv, mutableEnvironment = envp
		var owner: OpaquePointer?
		let inheritance: ergopti_owned_stream_inheritance = { context, actions in
			guard let context, let actions else { return EINVAL }
			let lease = Unmanaged<OwnedRuntimeInstalledPeerOwner.CLIImageLease>.fromOpaque(context).takeUnretainedValue()
			guard lease.current() else { return ESTALE }
			do {
				try lease.installLifecycleInheritance(actions: &actions.pointee)
				return lease.current() ? 0 : ESTALE
			} catch { return EACCES }
		}
		let prepared = mutableArguments.withUnsafeMutableBufferPointer { arguments in
			mutableEnvironment.withUnsafeMutableBufferPointer { environment in
				ergopti_owned_stream_prepare(image.executablePath, arguments.baseAddress, environment.baseAddress,
					input[0], output[1], errors[1], inheritance, Unmanaged.passUnretained(image).toOpaque(), &owner)
			}
		}
		for descriptor in [input[0], output[1], errors[1]] { closePipe(descriptor) }
		var inputDescriptor = input[1]
		var readsClosed = false, refusalParked = false
		defer {
			if !refusalParked {
				if inputDescriptor >= 0 { closePipe(inputDescriptor) }
				if !readsClosed { closePipe(output[0]); closePipe(errors[0]) }
			}
		}
		guard let retained = owner else {
			if inputDescriptor >= 0 { closePipe(inputDescriptor); inputDescriptor = -1 }
			closePipe(output[0]); closePipe(errors[0]); readsClosed = true
			return settleImage() ? (prepared == 0 ? 70 : 77) : 70
		}
		func parkOriginalDebt() -> Int32 {
			refusalParked = true
			let descriptors = ([inputDescriptor] + (readsClosed ? [] : [output[0], errors[0]])).filter { $0 >= 0 }
			let debt = RefusedCustody(program: retained, peer: peer, image: image,
				console: console, descriptors: descriptors)
			debtLock.lock(); refusedCustody.append(debt); debtLock.unlock()
			return 70
		}
		var cancelled = prepared != 0 || !peer.current() || !image.current()
		if !cancelled { cancelled = !image.guestCurrent(ergopti_owned_program_prepared_identity(retained)) }
		var activated = false
		if !cancelled {
			let receipt = ergopti_owned_program_activate(retained)
			activated = receipt.active && !receipt.cancelled && receipt.error_code == 0
			cancelled = !activated || !peer.current() || !image.current()
		}
		// Native retirement remains owned even when transport setup refuses.
		cancelled = cancelled || ![STDIN_FILENO, STDOUT_FILENO, inputDescriptor, output[0], errors[0]].allSatisfy(nonblocking)
		_ = Darwin.signal(SIGPIPE, SIG_IGN)
		var inputEOF = false, outputEOF = false, errorEOF = false
		var outbound = Data(), inbound = Data()
		func receive(_ descriptor: Int32, into bytes: inout Data, eof: inout Bool) -> Bool {
			if eof { return true }
			var block = [UInt8](repeating: 0, count: 4096)
			let count = Darwin.read(descriptor, &block, block.count)
			if count == 0 { eof = true; return true }
			if count < 0 { return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR }
			guard count <= maximumPendingBytes - bytes.count else { return false }
			bytes.append(contentsOf: block.prefix(count))
			return true
		}
		func transmit(_ descriptor: Int32, from bytes: inout Data) -> Bool {
			if bytes.isEmpty { return true }
			let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, bytes.count) }
			if count < 0 { return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR }
			guard count > 0 else { return false }
			bytes.removeFirst(count)
			return true
		}
		let terminal = TerminalObservation()
		var cooperativeStop = false, cooperativeSent = false, terminalForwarded = false
		func receiveOutput() -> Bool {
			var block = Data()
			guard receive(output[0], into: &block, eof: &outputEOF),
				terminal.consume(block), block.count <= maximumPendingBytes - inbound.count else { return false }
			inbound.append(block)
			return true
		}
		while true {
			let receipt = ergopti_owned_program_poll(retained)
			if stopping() || inputEOF { cooperativeStop = true }
			if !peer.current() || !image.current() || console.failure() != nil { cancelled = true }
			if !receipt.leader_exited && activated && !cancelled &&
				!image.guestCurrent(ergopti_owned_program_active_identity(retained)) { cancelled = true }
			if cooperativeStop && !cooperativeSent && activated && !receipt.leader_exited && !cancelled {
				// Fixed cooperative TERM does not arm the original 50 ms forced-kill grace.
				if ergopti_owned_program_request_stream_stop(retained) != 0 { cancelled = true }
				else { cooperativeSent = true }
			}
			if !cooperativeStop && !cancelled {
				if !receive(STDIN_FILENO, into: &outbound, eof: &inputEOF) { cancelled = true }
				if inputDescriptor >= 0 && !transmit(inputDescriptor, from: &outbound) { cancelled = true }
			}
			// Both pipes remain consumed after cooperative stop. The real CLI terminal
			// record travels over the same originally owned output pipe, never caller input.
			if !receiveOutput() { cancelled = true }
			var diagnostics = Data()
			if !receive(errors[0], into: &diagnostics, eof: &errorEOF) || !diagnostics.isEmpty { cancelled = true }
			if !cancelled {
				if !transmit(STDOUT_FILENO, from: &inbound) { cancelled = true }
				if terminal.retired && inbound.isEmpty { terminalForwarded = true }
			} else {
				// Transport refusal never becomes success; Core retains unacknowledged debt.
				inbound.removeAll(keepingCapacity: true)
				_ = ergopti_owned_program_cancel(retained)
			}
			if receipt.retired {
				guard receipt.status_valid, receipt.error_code == 0 else { return parkOriginalDebt() }
				if inputDescriptor >= 0 { closePipe(inputDescriptor); inputDescriptor = -1 }
				if outputEOF && errorEOF && inbound.isEmpty {
					guard ergopti_owned_program_destroy(&owner) else { return parkOriginalDebt() }
					closePipe(output[0]); closePipe(errors[0]); readsClosed = true
					guard settleImage() else { return 70 }
					return activated && !cancelled && terminal.ended() && terminalForwarded
						&& receipt.exit_status == 0 ? 0 : 70
				}
			}
			var events = [pollfd(fd: outputEOF ? -1 : output[0], events: Int16(POLLIN), revents: 0),
				pollfd(fd: errorEOF ? -1 : errors[0], events: Int16(POLLIN), revents: 0),
				pollfd(fd: cooperativeStop || cancelled || inputEOF ? -1 : STDIN_FILENO, events: Int16(POLLIN), revents: 0),
				pollfd(fd: cancelled || inbound.isEmpty ? -1 : STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)]
			let waited = Darwin.poll(&events, nfds_t(events.count), 25)
			if waited < 0 && errno != EINTR { cancelled = true }
		}
	}
}
