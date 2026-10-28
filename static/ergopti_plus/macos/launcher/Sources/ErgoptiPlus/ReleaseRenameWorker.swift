// Sources/ErgoptiPlus/ReleaseRenameWorker.swift
//
// Publishes a chosen release without mv's directory nesting or copy fallback.

import Darwin
import Foundation

let kReleaseRenameFlag = "--release-rename"

/// The launcher remains the native authority even when the chosen release predates this role.
enum ReleaseRenameWorker {
	static func handles(arguments: [String]) -> Bool {
		arguments.count > 1 && arguments[1] == kReleaseRenameFlag
	}

	/// Probe receipts use the role's own ABI identifier, with no second protocol constant.
	static func run(arguments: [String]) -> Int32 {
		guard handles(arguments: arguments) else { return 1 }
		if arguments.count == 3 && arguments[2] == "probe" {
			return output(kReleaseRenameFlag + "\n", descriptor: STDOUT_FILENO) ? 0 : 1
		}
		if arguments.count == 8 && arguments[2] == "lock" { return lock(arguments: arguments) }
		guard arguments.count == 5, arguments[2] == "move" else { return 1 }
		return move(source: arguments[3], destination: arguments[4])
	}

	private static func output(_ message: String, descriptor: Int32) -> Bool {
		let bytes = Array(message.utf8)
		return bytes.withUnsafeBytes { buffer in
			var offset = 0
			while offset < buffer.count {
				let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
				if count < 0 && errno == EINTR { continue }
				guard count > 0 else { return false }
				offset += count
			}
			return true
		}
	}

	/// Keep one stable sibling inode: unlinking a lease would admit two independent locks.
	private static func lock(arguments: [String]) -> Int32 {
		let app = arguments[3], script = arguments[4], pid = arguments[5]
		let staged = arguments[6], previous = arguments[7]
		guard location(app) != nil, location(staged) != nil, previous == app + ".previous",
			!pid.isEmpty, pid.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
			pid.first != "0", !script.isEmpty, !script.utf8.contains(0),
			let (parent, name) = location(app + ".release-lock") else { return 1 }
		let parentFD = Darwin.open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		guard parentFD >= 0 else { return 2 }
		defer { Darwin.close(parentFD) }
		let opened = openat(parentFD, name, O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
		guard opened >= 0 else { return 2 }
		// Descriptor 3 belongs to the detached worker's ARMED pipe and is closed by it.
		let lease = fcntl(opened, F_DUPFD_CLOEXEC, 4)
		let openedClosed = Darwin.close(opened) == 0
		guard lease >= 0 else { return 2 }
		defer { Darwin.close(lease) }
		guard openedClosed, verifyLease(lease, parent: parentFD, name: name) else { return 2 }
		guard ergoptiFlock(lease, LOCK_EX | LOCK_NB) == 0 else {
			_ = output("Another release replacement owns the installation lease.\n", descriptor: STDERR_FILENO)
			return 4
		}
		guard verifyLease(lease, parent: parentFD, name: name), fcntl(lease, F_SETFD, 0) == 0,
			var argv = duplicateCStringVector(["/bin/sh", "-c", script, "swap", pid, app, staged, previous]) else { return 2 }
		defer { for case let value? in argv { free(value) } }
		// The fixed shell and its synchronous child chain retain the lease until exit.
		argv.withUnsafeMutableBufferPointer { vector in
			_ = execv("/bin/sh", vector.baseAddress!)
		}
		return 2
	}

	private static func verifyLease(_ descriptor: Int32, parent: Int32, name: String) -> Bool {
		var held = stat(), named = stat()
		return fstat(descriptor, &held) == 0 && fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0
			&& held.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && held.st_mode & 0o7777 == 0o600
			&& held.st_uid == geteuid() && held.st_nlink == 1 && held.st_size == 0
			&& held.st_dev == named.st_dev && held.st_ino == named.st_ino
	}

	private static func location(_ path: String) -> (String, String)? {
		guard path.hasPrefix("/"), !path.hasSuffix("/"), !path.utf8.contains(0) else { return nil }
		let value = path as NSString
		let name = value.lastPathComponent
		guard !name.isEmpty, name != ".", name != ".." else { return nil }
		return (value.deletingLastPathComponent, name)
	}

	/// Parent descriptors bind both native names for one exclusive same-filesystem rename.
	static func move(source: String, destination: String) -> Int32 {
		guard let (sourceParent, sourceName) = location(source),
			let (destinationParent, destinationName) = location(destination) else { return 1 }
		let sourceFD = Darwin.open(sourceParent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		guard sourceFD >= 0 else { return 2 }
		let destinationFD = Darwin.open(destinationParent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		guard destinationFD >= 0 else { _ = Darwin.close(sourceFD); return 2 }
		let result = rename(sourceFD: sourceFD, sourceName: sourceName,
			destinationFD: destinationFD, destinationName: destinationName)
		let sourceClosed = Darwin.close(sourceFD) == 0
		let destinationClosed = Darwin.close(destinationFD) == 0
		return sourceClosed && destinationClosed ? result : 2
	}

	private static func rename(sourceFD: Int32, sourceName: String,
		destinationFD: Int32, destinationName: String) -> Int32 {
		var source = stat(), sourceParent = stat(), destinationParent = stat()
		guard fstatat(sourceFD, sourceName, &source, AT_SYMLINK_NOFOLLOW) == 0,
			source.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
			fstat(sourceFD, &sourceParent) == 0, fstat(destinationFD, &destinationParent) == 0,
			source.st_dev == destinationParent.st_dev, sourceParent.st_dev == destinationParent.st_dev else { return 2 }
		guard renameatx_np(sourceFD, sourceName, destinationFD, destinationName, UInt32(RENAME_EXCL)) == 0 else {
			let status = errno
			_ = output("Exclusive release rename refused (errno \(status)).\n", descriptor: STDERR_FILENO)
			return 3
		}
		return 0
	}
}
