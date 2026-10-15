// Sources/ErgoptiPlus/OwnedVirtualHIDDaemonReportMainOperation.swift
import Cocoa
import CPOSIXCompatibility
import CryptoKit
import Darwin
import Foundation
import Security

/// Explicit administrator-backed historical observation, never automatic startup or driver maintenance.
final class OwnedVirtualHIDDaemonReportMainOperation {
	enum Result { case pending, historical(OwnedVirtualHIDDaemonReportProtocol.Values), unavailable, cancelled, cleanupPending }
	final class Issuer {
		fileprivate let original: OwnedVirtualHIDDaemonReportMainOperation
		fileprivate let leaf: Data
		fileprivate init(_ original: OwnedVirtualHIDDaemonReportMainOperation) { self.original = original; leaf = original.publisher!.leaf }
		func current() -> Bool { original.sourceCurrent() }
	}
	final class HelperExpectation {
		private let issuer: Issuer, channel: OwnedVirtualHIDDaemonReportRequestChannel.Main, hashes: Set<Data>, stage: URL
		fileprivate init(issuer: Issuer, channel: OwnedVirtualHIDDaemonReportRequestChannel.Main, hashes: Set<Data>, stage: URL) {
			self.issuer = issuer; self.channel = channel; self.hashes = hashes; self.stage = stage
		}
		func belongs(to channel: OwnedVirtualHIDDaemonReportRequestChannel.Main) -> Bool { self.channel === channel && issuer.current() }
		func matches(_ guest: SecCode, channel: OwnedVirtualHIDDaemonReportRequestChannel.Main) -> Bool {
			guard belongs(to: channel), issuer.current(),
				OwnedRuntimePublisherSignature.currentLeaf(guest, role: .installer) == issuer.leaf else { return false }
			var code: SecStaticCode?, path: CFURL?
			guard SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
				let fields = OwnedRuntimePublisherSignature.information(code, role: .installer),
				let values = fields[kSecCodeInfoCdHashes as String] as? [Data], values.count == 2, Set(values) == hashes,
				SecCodeCopyPath(code, [], &path) == errSecSuccess, let path else { return false }
			let actual = (path as URL).standardizedFileURL
			return (actual == stage || actual == stage.appendingPathComponent("Contents/MacOS/ErgoptiPlus-Runtime-Installer")) && issuer.current()
		}
	}
	private static let rootsLock = NSLock(); private static var roots: [OwnedVirtualHIDDaemonReportMainOperation] = []
	private let lock = NSRecursiveLock(), sourceLock = NSRecursiveLock(), creator = getpid()
	private var birth = ergopti_owned_program_observation(), publisher: OwnedRuntimePublisherIdentity?, publisherAttempted = false
	private var queryOwner: OpaquePointer?, queryAttempted = false, queryNativeClosed = false
	private var queryDescriptors: [OwnedVHDReportDescriptor] = []
	private var principal: SecCode?, source: OwnedRuntimeInstallTree?, sourceAttempted = false, sourceClosed = false
	private var channel: OwnedVirtualHIDDaemonReportRequestChannel.Main?, expectation: HelperExpectation?
	private var entered = false, scriptFrames = 0, scriptFinished = false, cancelled = false, stopped = false, refused = false, closed = false
	private var scriptReturned = false, adminEntered = false, result: Result = .pending
	private init() {}
	static func handles(arguments: [String]) -> Bool { arguments.count == 2 && arguments[1] == "--request-virtual-hid-daemon-report" }
	static func acquire() -> OwnedVirtualHIDDaemonReportMainOperation {
		let owner = OwnedVirtualHIDDaemonReportMainOperation(); rootsLock.lock(); roots.append(owner); rootsLock.unlock()
		guard !Thread.isMainThread, getuid() != 0, getuid() == geteuid(), handles(arguments: CommandLine.arguments) else { owner.refused = true; return owner }
		owner.publisherAttempted = true; owner.publisher = OwnedRuntimePublisherIdentity.currentLauncher()
		owner.birth = ergopti_owned_program_observe(owner.creator)
		guard owner.publisher?.current() == true, SecCodeCopySelf([], &owner.principal) == errSecSuccess, owner.sourceCurrent() else { owner.refused = true; return owner }
		return owner
	}
	private func sourceCurrent() -> Bool {
		sourceLock.lock(); defer { sourceLock.unlock() }
		guard !closed, creator == getpid(), getuid() != 0, getuid() == geteuid(), publisher?.current() == true, let principal,
			OwnedRuntimePublisherSignature.currentLeaf(principal, role: .launcher) == publisher?.leaf else { return false }
		let now = ergopti_owned_program_observe(creator)
		return now.error_code == 0 && !now.nonlive && now.process_id == creator && birth.process_id == creator && birth.error_code == 0 && !birth.nonlive
			&& now.start_seconds == birth.start_seconds && now.start_microseconds == birth.start_microseconds
	}
	/// Only queues this original operation. The visible OS prompt is still required before a Root invocation.
	func start() -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard !entered else { return false }
		guard !refused, !stopped, sourceCurrent() else { refused = true; result = .unavailable; return false }; entered = true; scriptFrames = 1
		DispatchQueue.global(qos: .userInitiated).async {
			self.prepareAndPrompt()
			self.lock.lock(); self.scriptFrames = 0; self.scriptFinished = true; self.lock.unlock()
		}
		return true
	}
	func requestStop() { lock.lock(); stopped = true; let channel = channel; lock.unlock(); _ = channel?.withdraw() }
	private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
	private static func appleQuote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
	private func prepareAndPrompt() {
		guard sourceCurrent(), let resources = Bundle.main.resourceURL else { lock.lock(); refused = true; lock.unlock(); return }
		var selfImage = ergopti_vhd_report_self_image()
		guard ergopti_vhd_report_self_image_capture(&selfImage) == 0, selfImage.pid == creator, sourceCurrent() else { markRefused(); return }
		let helper = resources.appendingPathComponent("OwnedRuntimeInstaller/ErgoptiPlus-Runtime-Installer.app")
		var helperIdentity = stat(); let helperStatus = lstat(helper.path, &helperIdentity), helperError = errno
		guard helperStatus == 0, helperIdentity.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { _ = helperError; markRefused(); return }
		lock.lock(); sourceAttempted = true; lock.unlock()
		do {
			let source = try OwnedRuntimeInstallTree(root: helper, protected: false); lock.lock(); self.source = source; lock.unlock()
			var code: SecStaticCode?
			guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
				let fields = OwnedRuntimePublisherSignature.information(code, role: .installer),
				let certificates = fields[kSecCodeInfoCertificates as String] as? [SecCertificate], let certificate = certificates.first,
				SecCertificateCopyData(certificate) as Data == publisher?.leaf,
				let hashes = fields[kSecCodeInfoCdHashes as String] as? [Data], hashes.count == 2, Set(hashes).count == 2,
				hashes.allSatisfy({ $0.count == 20 || $0.count == 32 }) else { markRefused(); return }
			let bytes = try Data(contentsOf: helper.appendingPathComponent("Contents/MacOS/ErgoptiPlus-Runtime-Installer"))
			guard OwnedRuntimeInstallOwner.systemClosedExecutableForInstaller(bytes) else { markRefused(); return }; try source.verify()
			guard queryPurpose(helper: helper, hashes: Set(hashes)), sourceCurrent(), let leaf = publisher?.leaf else { markRefused(); return }
			let issuer = Issuer(self), channel = OwnedVirtualHIDDaemonReportRequestChannel.Main.acquire(from: issuer)
			lock.lock(); self.channel = channel; let stopped = self.stopped; lock.unlock()
			guard !stopped, channel.current() else { markRefused(); return }
			let generation = UUID().uuidString, stage = URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus/.runtime-installer-" + generation + "/Helper.app")
			let expectation = HelperExpectation(issuer: issuer, channel: channel, hashes: Set(hashes), stage: stage)
			let leafHash = Insecure.SHA1.hash(data: leaf).map { String(format: "%02x", $0) }.joined()
			let codeHashes = hashes.map { "cdhash H\"" + $0.map { String(format: "%02x", $0) }.joined() + "\"" }.sorted().joined(separator: " or ")
			let requirement = "identifier \"com.ergoptiplus.app.runtime-installer\" and certificate leaf = H\"" + leafHash + "\" and (" + codeHashes + ")"
			let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
			guard source.releaseOwnedDescriptors(), sourceCurrent(), channel.current() else { markRefused(); return }
			lock.lock(); sourceClosed = true; self.expectation = expectation; lock.unlock()
			let program = Self.stagingProgram(source: helper.path, stage: stage, requirement: requirement, digest: digest, route: channel.path)
			guard sourceCurrent(), channel.current(), let script = NSAppleScript(source: "do shell script " + Self.appleQuote(program) + " with administrator privileges") else { markRefused(); return }
			lock.lock(); guard !stopped else { lock.unlock(); markRefused(); return }; adminEntered = true; lock.unlock()
			var error: NSDictionary?; let returned = script.executeAndReturnError(&error)
			lock.lock(); cancelled = error?[NSAppleScript.errorNumber] as? Int == -128; scriptReturned = returned != nil && error == nil; lock.unlock()
		} catch { markRefused() }
	}
	/// A capability enquiry is data only. The original child, captures and native cleanup must all finish before admin.
	private func queryPurpose(helper: URL, hashes: Set<Data>) -> Bool {
		guard let began = OwnedVirtualHIDDaemonReportClock.now(), let source, sourceCurrent() else { return false }
		// This exact headless Main invocation is the original native query supervisor.
		// No child or administrator operation has been acquired before isolation.
		guard getsid(0) == creator || ergopti_owned_program_create_private_session() == 0,
			getsid(0) == creator, getpgid(0) == creator, sourceCurrent() else { return false }
		let executable = helper.appendingPathComponent("Contents/MacOS/ErgoptiPlus-Runtime-Installer").path
		func inputsCurrent() -> Bool {
			lock.lock(); let stopped = self.stopped; lock.unlock()
			guard !stopped, sourceCurrent(), OwnedVirtualHIDDaemonReportClock.remains(began) else { return false }
			do { try source.verify(); return true } catch { return false }
		}
		func childCurrent(_ identity: ergopti_owned_program_observation) -> Bool {
			guard identity.error_code == 0, !identity.nonlive, identity.process_id > 1 else { return false }
			let fresh = ergopti_owned_program_observe(identity.process_id)
			guard fresh.error_code == 0, !fresh.nonlive, fresh.process_id == identity.process_id,
				fresh.start_seconds == identity.start_seconds, fresh.start_microseconds == identity.start_microseconds else { return false }
			var guest: SecCode?, code: SecStaticCode?, path: CFURL?
			let attributes = [kSecGuestAttributePid as String: NSNumber(value: identity.process_id)] as CFDictionary
			guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest,
				OwnedRuntimePublisherSignature.currentLeaf(guest, role: .installer) == publisher?.leaf,
				SecCodeCopyStaticCode(guest, [], &code) == errSecSuccess, let code,
				let fields = OwnedRuntimePublisherSignature.information(code, role: .installer),
				let actual = fields[kSecCodeInfoCdHashes as String] as? [Data], actual.count == 2, Set(actual) == hashes,
				SecCodeCopyPath(code, [], &path) == errSecSuccess, let path else { return false }
			let named = (path as URL).standardizedFileURL
			return (named == helper || named.path == executable) && inputsCurrent()
		}
		func makePipe() -> (OwnedVHDReportDescriptor, OwnedVHDReportDescriptor, OwnedVHDReportDescriptor)? {
			var raw: [Int32] = [-1, -1]
			guard Darwin.pipe(&raw) == 0 else { return nil }
			let reader = OwnedVHDReportDescriptor(raw[0]), writer = OwnedVHDReportDescriptor(raw[1])
			queryDescriptors.append(reader); queryDescriptors.append(writer)
			guard reader.capture(), writer.capture() else { return nil }
			// This duplicate pins the original pipe object until both originals have checked closure.
			let duplicate = fcntl(reader.number, F_DUPFD_CLOEXEC, 0)
			guard duplicate >= 0 else { return nil }
			let witness = OwnedVHDReportDescriptor(duplicate); queryDescriptors.append(witness)
			guard witness.capture(), let a = reader.identity, let b = witness.identity, OwnedVHDReportDescriptor.same(a, b) else { return nil }
			for descriptor in [reader, writer] {
				guard descriptor.current(), fcntl(descriptor.number, F_SETFD, FD_CLOEXEC) == 0, descriptor.current() else { return nil }
			}
			let flags = fcntl(reader.number, F_GETFL)
			guard flags >= 0, reader.current(), fcntl(reader.number, F_SETFL, flags | O_NONBLOCK) == 0, reader.current() else { return nil }
			return (reader, writer, witness)
		}
		guard let output = makePipe(), let errors = makePipe(), inputsCurrent() else { return false }
		let arguments = [executable, "--query-vhd-daemon-report-purpose"].map { strdup($0) } + [nil]
		let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"].map { strdup($0) } + [nil]
		defer { for case let p? in arguments { free(p) }; for case let p? in environment { free(p) } }
		guard arguments.dropLast().allSatisfy({ $0 != nil }), environment.dropLast().allSatisfy({ $0 != nil }) else { return false }
		var argv = arguments, envp = environment
		queryAttempted = true
		let prepared = argv.withUnsafeMutableBufferPointer { args in
			envp.withUnsafeMutableBufferPointer { env in
				ergopti_owned_query_prepare(executable, args.baseAddress, env.baseAddress, output.1.number, errors.1.number, &queryOwner)
			}
		}
		if queryOwner == nil {
			// The native ABI publishes every acquired child, including post-spawn refusals.
			// A nonzero error with no owner therefore proves only no native acquisition.
			if prepared != 0 { queryNativeClosed = true; _ = closeQueryDescriptors() }
			return false
		}
		guard output.1.close(), errors.1.close(), let owned = queryOwner else { return false }
		let original = ergopti_owned_program_prepared_identity(owned)
		var cancelled = prepared != 0 || !inputsCurrent() || !childCurrent(original)
		if !cancelled {
			let activated = ergopti_owned_program_activate(owned)
			cancelled = !activated.active || activated.cancelled || activated.error_code != 0
			if !cancelled && !childCurrent(original) {
				// The already-validated suspended image may finish before this live recut.
				// Only its original native owner can distinguish completion from wrong/live identity.
				let completion = ergopti_owned_program_poll(owned)
				cancelled = completion.error_code != 0 || !completion.leader_exited
			}
		}
		var bytes = Data(), errorBytes = Data(), outputEOF = false, errorEOF = false
		func drain(_ reader: OwnedVHDReportDescriptor, into bytes: inout Data, eof: inout Bool, maximum: Int) -> Bool {
			if eof { return true }; guard reader.current() else { return false }
			var buffer = [UInt8](repeating: 0, count: 128)
			let count = Darwin.read(reader.number, &buffer, buffer.count), saved = errno
			guard reader.current() else { return false }
			if count == 0 { eof = true; return true }
			if count < 0 { return saved == EAGAIN || saved == EWOULDBLOCK || saved == EINTR }
			guard count <= maximum - bytes.count else { return false }
			bytes.append(contentsOf: buffer.prefix(count)); return true
		}
		while let owned = queryOwner {
			if !inputsCurrent() { cancelled = true }
			if !drain(output.0, into: &bytes, eof: &outputEOF, maximum: 128)
				|| !drain(errors.0, into: &errorBytes, eof: &errorEOF, maximum: 0) { cancelled = true }
			if cancelled { _ = ergopti_owned_program_cancel(owned) }
			let receipt = ergopti_owned_program_poll(owned)
			if receipt.retired {
				guard ergopti_owned_program_destroy(&queryOwner) else { return false }
				queryNativeClosed = true
				let captureOK = drain(output.0, into: &bytes, eof: &outputEOF, maximum: 128)
					&& drain(errors.0, into: &errorBytes, eof: &errorEOF, maximum: 0) && outputEOF && errorEOF
				guard closeQueryDescriptors() else { return false }
				return !cancelled && captureOK && receipt.error_code == 0 && receipt.status_valid && receipt.exit_status == 0
					&& Self.acceptsPurposeReply(bytes, errors: errorBytes, status: receipt.exit_status) && inputsCurrent()
			}
			guard OwnedVirtualHIDDaemonReportClock.remains(began) else {
				_ = ergopti_owned_program_cancel(owned); return false // Retained native owner remains explicit cleanup debt.
			}
			Thread.sleep(forTimeInterval: 0.01)
		}
		return false
	}
	static func acceptsPurposeReply(_ bytes: Data, errors: Data, status: Int32) -> Bool {
		status == 0 && errors.isEmpty && bytes == Data("OWNED_VHD_DAEMON_REPORT_PURPOSE|1|readonly-historical\n".utf8)
	}
	private func closeQueryDescriptors() -> Bool {
		// Witnesses were appended after each pipe's originals and therefore close last, never first.
		for descriptor in queryDescriptors { guard descriptor.close() else { return false } }
		return true
	}

	private func markRefused() { lock.lock(); refused = true; lock.unlock() }
	/// Fixed system tools only. No runtime publication/service/driver command is admitted by this purpose.
	private static func stagingProgram(source: String, stage: URL, requirement: String, digest: String, route: String) -> String {
		let parent = "/Library/Application Support/ErgoptiPlus", directory = stage.deletingLastPathComponent().path
		let executable = stage.appendingPathComponent("Contents/MacOS/ErgoptiPlus-Runtime-Installer").path
		let program = """
		set -eu
		assert_directory() {
		  [ ! -L "$1" ] && [ -d "$1" ] && [ "$(/usr/bin/stat -f '%u' "$1")" = 0 ] || exit 77
		  task_mode=$(/usr/bin/stat -f '%Lp' "$1")
		  case "$task_mode" in *[!0-7]*|'') exit 77 ;; esac
		  [ $((0$task_mode & 0022)) = 0 ] || exit 77
		  task_listing=$(/bin/ls -lde "$1"); task_permissions=${task_listing%% *}
		  case "$task_permissions" in ??????????|??????????@) ;; *) exit 77 ;; esac
		}
		assert_directory '/'; assert_directory '/Library'; assert_directory '/Library/Application Support'
		if [ ! -e \(quote(parent)) ] && [ ! -L \(quote(parent)) ]; then /bin/mkdir -m 0755 \(quote(parent)); fi
		assert_directory \(quote(parent))
		/bin/mkdir -m 0700 \(quote(directory))
		/usr/bin/ditto --noqtn --noacl \(quote(source)) \(quote(stage.path))
		task_bad=$(/usr/bin/find \(quote(directory)) -type l -print -quit); [ -z "$task_bad" ] || exit 77
		task_bad=$(/usr/bin/find \(quote(directory)) ! \\( -type f -o -type d \\) -print -quit); [ -z "$task_bad" ] || exit 77
		task_bad=$(/usr/bin/find \(quote(directory)) -type f -links +1 -print -quit); [ -z "$task_bad" ] || exit 77
		task_bad=$(/usr/bin/find \(quote(directory)) \\( -perm -4000 -o -perm -2000 \\) -print -quit); [ -z "$task_bad" ] || exit 77
		/usr/sbin/chown -R root:wheel \(quote(directory)); /bin/chmod -RN \(quote(directory)); /bin/chmod -R go-w \(quote(directory))
		assert_directory \(quote(directory))
		/usr/bin/codesign --verify --strict --all-architectures --deep --test-requirement \(quote(requirement)) \(quote(stage.path))
		task_digest=$(/usr/bin/shasum -a 256 \(quote(executable))); task_digest=${task_digest%% *}; [ "$task_digest" = \(quote(digest)) ] || exit 77
		/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin ERGOPTI_VHD_REPORT_ROUTE=\(quote(route)) \(quote(executable)) --virtual-hid-daemon-report-worker
		"""
		return "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c " + quote(program)
	}
	func poll() -> Result {
		lock.lock(); defer { lock.unlock() }; if closed { return result }
		guard !Thread.isMainThread else { return .unavailable }
		if let channel, let expectation, !channel.hasAcceptedPeer() { _ = channel.accept(expected: expectation) }
		if let channel, channel.hasAcceptedPeer() {
			if stopped { _ = channel.withdraw() } else { _ = channel.sendRequest() }
			let terminal = channel.receive()
			if let status = channel.exited(), scriptFinished {
				let normal = status >= 0 && status & 0x7f == 0, code = (status >> 8) & 0xff
				if let terminal, normal, code == 0, terminal.result == 1, !stopped, !refused {
					let f = terminal.fields
					result = .historical(.init(driverActivated: f[0] == 1, driverConnected: f[1] == 1, driverVersionMismatched: f[2] == 1,
						virtualHIDKeyboardReady: f[3] == 1, virtualHIDPointingReady: f[4] == 1))
				} else { result = normal && code == 77 && terminal?.result == 2 ? .unavailable : .cleanupPending }
				return retire() ? result : .cleanupPending
			}
		}
		if scriptFinished && channel?.hasAcceptedPeer() != true {
			result = cancelled ? .cancelled : adminEntered ? .cleanupPending : .unavailable
			if !adminEntered || cancelled { return retire() ? result : .cleanupPending }
			return .cleanupPending // A returned script with no authenticated helper leaves staging custody unknown.
		}
		if !entered && refused { result = .unavailable; return retire() ? result : .cleanupPending }
		return .pending
	}
	func retire() -> Bool {
		lock.lock(); defer { lock.unlock() }; if closed { return true }; guard scriptFrames == 0, !adminEntered || cancelled || channel?.exited() != nil else { return false }
		if queryAttempted && !queryNativeClosed { return false }
		guard closeQueryDescriptors() else { return false }
		if let channel, !channel.retire() { return false }
		if sourceAttempted && !sourceClosed {
			guard let source, source.releaseOwnedDescriptors() else { return false }; sourceClosed = true
		}
		sourceLock.lock(); defer { sourceLock.unlock() }
		if let publisher { guard publisher.retire() else { return false }; self.publisher = nil }
		else if publisherAttempted { return false }
		closed = true; Self.rootsLock.lock(); Self.roots.removeAll { $0 === self }; Self.rootsLock.unlock(); return true
	}
	func retired() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }
	/// Deliberate signed Main CLI request. The administrator prompt is never a resident startup side effect.
	static func run(arguments: [String]) -> Int32 {
		guard handles(arguments: arguments), !Thread.isMainThread else { return 64 }
		let owner = acquire(); _ = owner.start()
		while true {
			switch owner.poll() {
			case .pending: Thread.sleep(forTimeInterval: 0.02)
			case .historical(let values):
				let fields = [values.driverActivated, values.driverConnected, values.driverVersionMismatched, values.virtualHIDKeyboardReady, values.virtualHIDPointingReady]
				let bytes = Data(("OWNED_VHD_DAEMON_REPORT|1|historical-observer-connection|" + fields.map { $0 ? "1" : "0" }.joined(separator: "|") + "|remote-cleanup-unobserved\n").utf8)
				do { try FileHandle.standardOutput.write(contentsOf: bytes) } catch { return 75 }; return 0
			case .unavailable: return 77
			case .cancelled: return 1
			case .cleanupPending: return 75
			}
		}
	}
}

// Main-only extension: this file is never enrolled in the privileged helper's source roster.
extension OwnedVirtualHIDDaemonReportRequestChannel {

	final class Main {
		private static let rootsLock = NSLock(); private static var roots: [Main] = []
		private let lock = NSRecursiveLock(), issuer: OwnedVirtualHIDDaemonReportMainOperation.Issuer
		private var descriptors: [OwnedVHDReportDescriptor] = [], directory: OwnedVHDReportDescriptor?, listener: OwnedVHDReportDescriptor?, stream: OwnedVHDReportDescriptor?, monitor: OwnedVHDReportDescriptor?
		private var routeIdentity: stat?, directoryIdentity: stat?, directoryCreated = false, routeCreated = false
		private(set) var path = ""
		private var parent: OwnedVHDReportDescriptor?
		private var directoryPath = "", nonce = Data(), incoming = Data(), framingStart: UInt64?
		private var expected: OwnedVirtualHIDDaemonReportMainOperation.HelperExpectation?, born = ergopti_vhd_report_peer_identity(), peerCode: SecCode?
		private var terminal: OwnedVHDReportWire.Frame?, exitStatus: Int32?, refused = false, closed = false, requested = false, withdrawn = false
		private init(_ issuer: OwnedVirtualHIDDaemonReportMainOperation.Issuer) { self.issuer = issuer }
		static func acquire(from issuer: OwnedVirtualHIDDaemonReportMainOperation.Issuer) -> Main {
			let owner = Main(issuer); rootsLock.lock(); roots.append(owner); rootsLock.unlock()
			guard !Thread.isMainThread, issuer.current() else { owner.refused = true; return owner }
			var random = [UInt8](repeating: 0, count: 32); arc4random_buf(&random, random.count); owner.nonce = Data(random)
			guard random.contains(where: { $0 != 0 }) else { owner.refused = true; return owner }
			owner.directoryPath = "/private/tmp/.ergopti-vhd-report-" + random.prefix(16).map { String(format: "%02x", $0) }.joined()
			owner.path = owner.directoryPath + "/channel.sock"
			guard let parent = owner.retain(open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)) else { owner.refused = true; return owner }; owner.parent = parent
			guard mkdirat(parent.number, URL(fileURLWithPath: owner.directoryPath).lastPathComponent, 0o700) == 0 else { owner.refused = true; return owner }; owner.directoryCreated = true
			var named = stat(); guard lstat(owner.directoryPath, &named) == 0 else { owner.refused = true; return owner }; owner.directoryIdentity = named
			guard let directory = owner.retain(open(owner.directoryPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)),
				let held = directory.identity, OwnedVHDReportDescriptor.same(named, held), held.st_uid == getuid(), held.st_mode & 0o7777 == 0o700 else { owner.refused = true; return owner }
			owner.directory = directory
			guard let listener = owner.retain(Darwin.socket(AF_UNIX, SOCK_STREAM, 0), socket: true) else { owner.refused = true; return owner }; owner.listener = listener
			guard listener.retainSocketWitness(), configure(listener), var address = address(owner.path), owner.namespaceCurrent() else { owner.refused = true; return owner }
			let status = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener.number, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
			guard status == 0 else { owner.refused = true; return owner }; owner.routeCreated = true
			guard lstat(owner.path, &named) == 0 else { owner.refused = true; return owner }; owner.routeIdentity = named
			guard named.st_uid == getuid(), listener.current(), chmod(owner.path, 0o600) == 0 else { owner.refused = true; return owner }
			var protected = stat(); guard lstat(owner.path, &protected) == 0, named.st_dev == protected.st_dev, named.st_ino == protected.st_ino,
				protected.st_uid == named.st_uid, protected.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), protected.st_mode & 0o7777 == 0o600 else { owner.refused = true; return owner }
			owner.routeIdentity = protected
			guard owner.namespaceCurrent(), listener.current(), Darwin.listen(listener.number, 1) == 0, listener.current(), issuer.current() else { owner.refused = true; return owner }; return owner
		}
		private func retain(_ raw: Int32, socket: Bool = false) -> OwnedVHDReportDescriptor? {
			guard raw >= 0 else { return nil }; let fd = OwnedVHDReportDescriptor(raw, socket: socket); descriptors.append(fd); return fd.capture() ? fd : nil
		}
		private func namespaceCurrent() -> Bool {
			guard !closed, let directory, directory.current(), let expected = directoryIdentity else { return false }
			var named = stat(); guard lstat(directoryPath, &named) == 0, OwnedVHDReportDescriptor.same(expected, named) else { return false }
			if let expected = routeIdentity { guard fstatat(directory.number, "channel.sock", &named, AT_SYMLINK_NOFOLLOW) == 0, OwnedVHDReportDescriptor.same(expected, named) else { return false } }
			return directory.current()
		}
		func current() -> Bool { lock.lock(); defer { lock.unlock() }; return !refused && namespaceCurrent() && issuer.current() && !withdrawn }
		func accept(expected: OwnedVirtualHIDDaemonReportMainOperation.HelperExpectation) -> Bool {
			lock.lock(); defer { lock.unlock() }; guard !refused, namespaceCurrent(), issuer.current(), stream == nil, let listener, listener.current(), expected.belongs(to: self) else { return false }; self.expected = expected
			let raw = Darwin.accept(listener.number, nil, nil), saved = errno
			if raw >= 0 { stream = retain(raw, socket: true) }
			guard listener.current(), namespaceCurrent() else { refused = true; return false }
			if raw < 0 { if saved != EINTR && saved != EAGAIN && saved != EWOULDBLOCK { refused = true }; return false }
			guard let stream, stream.retainSocketWitness(), configure(stream), ergopti_vhd_report_channel_peer(stream.number, &born) == 0, born.uid == 0 else { refused = true; return false }
			let attrs = [kSecGuestAttributePid as String: NSNumber(value: born.pid)] as CFDictionary
			guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &peerCode) == errSecSuccess, pairCurrent() else { refused = true; return false }
			var error: Int32 = 0; let rawMonitor = ergopti_process_exit_monitor_open(born.pid, &error)
			if rawMonitor >= 0 { monitor = retain(rawMonitor) }
			guard error == 0, monitor?.current() == true, pairCurrent() else { refused = true; return false }; return true
		}
		private func pairCurrent() -> Bool {
			guard !closed, !refused, namespaceCurrent(), issuer.current(), let stream, stream.current(), let peerCode, let expected,
				expected.matches(peerCode, channel: self) else { return false }; var value = ergopti_vhd_report_peer_identity()
			return ergopti_vhd_report_channel_peer(stream.number, &value) == 0 && value.pid == born.pid && value.uid == 0
				&& value.start_seconds == born.start_seconds && value.start_microseconds == born.start_microseconds && stream.current()
		}
		func sendRequest() -> Bool {
			lock.lock(); defer { lock.unlock() }; guard !requested, !withdrawn, pairCurrent(), let stream,
				let data = OwnedVHDReportWire.encode(direction: 0, operation: 1, nonce: nonce) else { return false }
			guard write(data, fd: stream, current: { self.pairCurrent() }) else { refused = true; return false }; requested = true; return true
		}
		func withdraw() -> Bool {
			lock.lock(); defer { lock.unlock() }; withdrawn = true
			guard terminal == nil, pairCurrent(), let stream, let data = OwnedVHDReportWire.encode(direction: 0, operation: 2, nonce: nonce) else { return false }
			return write(data, fd: stream, current: { self.pairCurrent() })
		}
		private func receiveCurrent() -> Bool {
			guard !closed, !refused, namespaceCurrent(), issuer.current(), stream?.current() == true, expected?.belongs(to: self) == true else { return false }
			return pairCurrent() || exited() != nil
		}
		func receive() -> OwnedVHDReportWire.Frame? {
			lock.lock(); defer { lock.unlock() }; if let terminal { return terminal }
			guard receiveCurrent(), let stream, let data = read(fd: stream, buffer: &incoming, start: &framingStart, refused: &refused, current: { self.receiveCurrent() }) else { return nil }
			guard let frame = OwnedVHDReportWire.decode(data, direction: 1, nonce: nonce) else { refused = true; return nil }; terminal = frame; return frame
		}
		func exited() -> Int32? {
			lock.lock(); defer { lock.unlock() }; if let exitStatus { return exitStatus }
			guard let monitor, monitor.current(), expected?.belongs(to: self) == true, issuer.current(), namespaceCurrent() else { return nil }
			var status: Int32 = 0, error: Int32 = 0; let result = ergopti_process_exit_monitor_read(monitor.number, &status, &error)
			guard monitor.current(), result >= 0, error == 0 else { refused = true; return nil }
			if result == 1 { exitStatus = status }; return exitStatus
		}
		func hasAcceptedPeer() -> Bool { lock.lock(); defer { lock.unlock() }; return monitor != nil }
		func failed() -> Bool { lock.lock(); defer { lock.unlock() }; return refused }
		func retire() -> Bool {
			lock.lock(); defer { lock.unlock() }; if closed { return true }
			if monitor != nil && exited() == nil { return false }; var complete = true
			for held in descriptors.reversed() where held !== directory && held !== parent { if !held.close() { complete = false } }
			guard complete else { refused = true; return false }
			if routeCreated {
				guard let expected = routeIdentity, let directory, directory.current() else { return false }; var now = stat()
				guard fstatat(directory.number, "channel.sock", &now, AT_SYMLINK_NOFOLLOW) == 0, OwnedVHDReportDescriptor.same(expected, now), directory.current(), unlinkat(directory.number, "channel.sock", 0) == 0 else { return false }; routeCreated = false
			}
			if directoryCreated {
				guard let expected = directoryIdentity, let directory, directory.current(), let parent, parent.current() else { return false }; var now = stat()
				guard fstatat(parent.number, URL(fileURLWithPath: directoryPath).lastPathComponent, &now, AT_SYMLINK_NOFOLLOW) == 0, OwnedVHDReportDescriptor.same(expected, now), directory.current(), parent.current(), unlinkat(parent.number, URL(fileURLWithPath: directoryPath).lastPathComponent, AT_REMOVEDIR) == 0 else { return false }; directoryCreated = false
			}
			guard directory?.close() ?? !directoryCreated, parent?.close() ?? true else { return false }
			closed = true; Self.rootsLock.lock(); Self.roots.removeAll { $0 === self }; Self.rootsLock.unlock(); return true
		}
		func retired() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }
	}
}
