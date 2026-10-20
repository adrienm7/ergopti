// Sources/ErgoptiPlus/OwnedRuntimeCoreLaunchctl.swift
// Fixed system launchctl commands own their unreaped native child until every timeout signal is complete.
import CPOSIXCompatibility
import Darwin
import Foundation
import Security

/// Arguments are closed at the production entry; output is retained internally and never exported as diagnostics.
enum OwnedRuntimeCoreLaunchctl {
	struct Observation { let status: Int32, bytes: Data }
	private struct ChildObservation { let status: Int32, bytes: Data, timedOut: Bool }
	static func run(arguments: [String]) throws -> Observation {
		guard arguments == ["print", "system/com.ergoptiplus.runtime.core"]
			|| arguments == ["bootout", "system/com.ergoptiplus.runtime.core"]
			|| arguments == ["bootstrap", "system", "/Library/LaunchDaemons/com.ergoptiplus.runtime.core.plist"]
			|| arguments == ["kickstart", "system/com.ergoptiplus.runtime.core"] else { throw OwnedRuntimeInstallFailure.source }
		let result = try child(path: "/bin/launchctl", arguments: arguments, timeout: 3)
		guard !result.timedOut else { throw OwnedRuntimeInstallFailure.cleanupPending }
		return Observation(status: result.status, bytes: result.bytes)
	}
	private static func ownedDescriptor(_ original: Int32) throws -> Int32 {
		guard original >= 0 else { throw OwnedRuntimeInstallFailure.source }
		let result = fcntl(original, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
		Darwin.close(original)
		guard result > STDERR_FILENO else { throw OwnedRuntimeInstallFailure.source }
		return result
	}
	private static func raw(_ strings: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
		var output: [UnsafeMutablePointer<CChar>?] = []
		for string in strings {
			guard !string.contains("\0"), let value = strdup(string) else {
				for case let pointer? in output { free(pointer) }; throw OwnedRuntimeInstallFailure.source
			}
			output.append(value)
		}; output.append(nil); return output
	}
	private static func systemCode(path: String, descriptor: Int32) throws {
		var held = stat(), named = stat(), code: SecStaticCode?, requirement: SecRequirement?
		guard fstat(descriptor, &held) == 0, lstat(path, &named) == 0,
			held.st_dev == named.st_dev, held.st_ino == named.st_ino, held.st_uid == 0,
			held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), held.st_mode & 0o6022 == 0,
			SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
			SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess, let requirement,
			SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
			throw OwnedRuntimeInstallFailure.signature
		}
		errno = 0
		if let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) {
			defer { acl_free(UnsafeMutableRawPointer(acl)) }
			var entry: acl_entry_t?; errno = 0
			guard acl_valid(acl) == 0, acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1, errno == EINVAL else {
				throw OwnedRuntimeInstallFailure.protection
			}
		} else if errno != ENOENT { throw OwnedRuntimeInstallFailure.protection } // Libc answers NULL/ENOENT for a file without an extended ACL (filesec_get_property): that is the empty ACL, not a refusal.
	}
	private static func child(path: String, arguments: [String], timeout: TimeInterval) throws -> ChildObservation {
		let parent = try OwnedRuntimeInstallTree(root: URL(fileURLWithPath: path).deletingLastPathComponent(), protected: true, includeChildren: false)
		let image = try ownedDescriptor(open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK))
		defer { Darwin.close(image) }; try systemCode(path: path, descriptor: image)
		var pipeDescriptors: [Int32] = [-1, -1]
		guard pipe(&pipeDescriptors) == 0 else { throw OwnedRuntimeInstallFailure.source }
		var readEnd: Int32 = -1, writeEnd: Int32 = -1
		do { readEnd = try ownedDescriptor(pipeDescriptors[0]) } catch { Darwin.close(pipeDescriptors[1]); throw error }
		defer { Darwin.close(readEnd) }
		writeEnd = try ownedDescriptor(pipeDescriptors[1])
		var writeClosed = false; defer { if !writeClosed { Darwin.close(writeEnd) } }
		let null = try ownedDescriptor(open("/dev/null", O_RDWR | O_CLOEXEC)); defer { Darwin.close(null) }
		let flags = fcntl(readEnd, F_GETFL)
		guard flags >= 0, fcntl(readEnd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw OwnedRuntimeInstallFailure.source }
		var actions: posix_spawn_file_actions_t?
		guard posix_spawn_file_actions_init(&actions) == 0 else { throw OwnedRuntimeInstallFailure.source }
		defer { posix_spawn_file_actions_destroy(&actions) }
		guard posix_spawn_file_actions_adddup2(&actions, null, STDIN_FILENO) == 0,
			posix_spawn_file_actions_adddup2(&actions, writeEnd, STDOUT_FILENO) == 0,
			posix_spawn_file_actions_adddup2(&actions, null, STDERR_FILENO) == 0 else { throw OwnedRuntimeInstallFailure.source }
		for descriptor in [null, readEnd, writeEnd, image] {
			guard posix_spawn_file_actions_addclose(&actions, descriptor) == 0 else { throw OwnedRuntimeInstallFailure.source }
		}
		var attributes: posix_spawnattr_t?
		guard posix_spawnattr_init(&attributes) == 0 else { throw OwnedRuntimeInstallFailure.source }
		defer { posix_spawnattr_destroy(&attributes) }
		guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0 else { throw OwnedRuntimeInstallFailure.source }
		var argv = try raw([path] + arguments); defer { for case let pointer? in argv { free(pointer) } }
		var env = try raw(["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"]); defer { for case let pointer? in env { free(pointer) } }
		// This isolated privileged worker restores zombie-producing semantics before its own spawn.
		guard ergopti_owned_child_reaping_restore() == 0 else {
			throw OwnedRuntimeInstallFailure.source
		}
		try parent.verifyAnchor(); try systemCode(path: path, descriptor: image)
		var pid: pid_t = 0
		let spawned = argv.withUnsafeMutableBufferPointer { arguments in
			env.withUnsafeMutableBufferPointer { environment in
				posix_spawn(&pid, path, &actions, &attributes, arguments.baseAddress, environment.baseAddress)
			}
		}
		guard spawned == 0, pid > 0 else { throw OwnedRuntimeInstallFailure.source }
		Darwin.close(writeEnd); writeClosed = true
		let deadline = ProcessInfo.processInfo.systemUptime + timeout
		var output = Data(), status: Int32 = 0, failure = false, eof = false
		func consume() {
			guard !eof else { return }
			var buffer = [UInt8](repeating: 0, count: 4096)
			while true {
				if ProcessInfo.processInfo.systemUptime >= deadline { return }
				let count = buffer.withUnsafeMutableBytes { Darwin.read(readEnd, $0.baseAddress, $0.count) }
				if count > 0 {
					guard output.count <= 131_072 - count else { failure = true; return }
					output.append(contentsOf: buffer.prefix(count)); continue
				}
				if count == 0 { eof = true; return }
				if errno == EINTR { continue }
				if errno == EAGAIN || errno == EWOULDBLOCK { return }
				failure = true; return
			}
		}
		while ProcessInfo.processInfo.systemUptime < deadline && !failure {
			consume()
			let result = waitpid(pid, &status, WNOHANG)
			if result == pid {
				consume()
				guard !failure, eof, status & 0x7f == 0 else { throw OwnedRuntimeInstallFailure.source }
				return ChildObservation(status: (status >> 8) & 0xff, bytes: output, timedOut: false)
			}
			if result == -1 && errno != EINTR { throw OwnedRuntimeInstallFailure.cleanupPending }
			var descriptor = pollfd(fd: readEnd, events: Int16(POLLIN | POLLHUP), revents: 0)
			let resultPoll = poll(&descriptor, 1, 20)
			if resultPoll < 0 && errno != EINTR { failure = true }
		}
		// This unreaped child PID cannot be reused while these signals remain owned here.
		_ = Darwin.kill(pid, SIGTERM)
		let gracefulDeadline = ProcessInfo.processInfo.systemUptime + 0.25
		while ProcessInfo.processInfo.systemUptime < gracefulDeadline {
			let result = waitpid(pid, &status, WNOHANG)
			if result == pid { return ChildObservation(status: (status >> 8) & 0xff, bytes: output, timedOut: true) }
			if result == -1 && errno != EINTR { throw OwnedRuntimeInstallFailure.cleanupPending }
			usleep(10_000)
		}
		_ = Darwin.kill(pid, SIGKILL)
		// Dedicated worker retains this exact child debt until native reap; no successor generation is admitted.
		var result: pid_t
		repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
		guard result == pid else { throw OwnedRuntimeInstallFailure.cleanupPending }
		return ChildObservation(status: (status >> 8) & 0xff, bytes: output, timedOut: true)
	}
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	static func fixtureUnrelatedDescriptorWasClosed() throws -> Bool {
		let source = open("/dev/null", O_RDONLY)
		guard source >= 0 else { throw OwnedRuntimeInstallFailure.source }; defer { Darwin.close(source) }
		let inherited = fcntl(source, F_DUPFD, 196)
		guard inherited >= 196 else { throw OwnedRuntimeInstallFailure.source }; defer { Darwin.close(inherited) }
		let flags = fcntl(inherited, F_GETFD)
		guard flags >= 0, flags & FD_CLOEXEC == 0 else { throw OwnedRuntimeInstallFailure.source }
		let observed = try child(path: "/bin/sh", arguments: ["-c", "test ! -e /dev/fd/" + String(inherited)], timeout: 1)
		return observed.status == 0 && !observed.timedOut
	}

	/// Actual native child probes grant no launchd, Core PID or production principal capability.
	static func fixtureEcho() throws -> Observation {
		let result = try child(path: "/bin/echo", arguments: ["owned-child"], timeout: 3)
		guard !result.timedOut else { throw OwnedRuntimeInstallFailure.cleanupPending }
		return Observation(status: result.status, bytes: result.bytes)
	}
	static func fixtureTimeoutWasReaped() throws -> Bool {
		let result = try child(path: "/bin/sleep", arguments: ["10"], timeout: 0.1)
		return result.timedOut
	}
	#endif
}
