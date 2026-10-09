// Sources/ErgoptiPlus/ManagedImageAlias.swift
// An explicit private lease preserves a retained source vnode and dylib layout.

import CPOSIXCompatibility
import CryptoKit
import Darwin
import Foundation

struct ManagedImageAliasProof {
	let nonce: String
	let directoryDevice: UInt64
	let directoryInode: UInt64
	let ancestorDevice: UInt64
	let ancestorInode: UInt64
	let leaseDevice: UInt64
	let leaseInode: UInt64
	let fingerprint: String
	static func parse(_ value: Any?) -> ManagedImageAliasProof? {
		guard let fields = value as? [String: Any], Set(fields.keys) == ["version", "nonce", "directory_device", "directory_inode", "ancestor_device", "ancestor_inode", "lease_device", "lease_inode", "binary_sha256"],
			ManagedBootstrapRequest.integer(fields["version"]) == 1,
			let nonce = fields["nonce"] as? String, nonce.utf8.count == 32,
			nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
			let directoryDevice = ManagedOllamaRequest.integer(fields["directory_device"]), directoryDevice <= UInt64(UInt32.max),
			let directoryInode = ManagedOllamaRequest.integer(fields["directory_inode"]), directoryInode > 0,
			let ancestorDevice = ManagedOllamaRequest.integer(fields["ancestor_device"]), ancestorDevice <= UInt64(UInt32.max),
			let ancestorInode = ManagedOllamaRequest.integer(fields["ancestor_inode"]), ancestorInode > 0,
			let leaseDevice = ManagedOllamaRequest.integer(fields["lease_device"]), leaseDevice <= UInt64(UInt32.max),
			let leaseInode = ManagedOllamaRequest.integer(fields["lease_inode"]), leaseInode > 0,
			let fingerprint = fields["binary_sha256"] as? String, fingerprint.utf8.count == 64,
			fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
		return ManagedImageAliasProof(nonce: nonce, directoryDevice: directoryDevice, directoryInode: directoryInode,
			ancestorDevice: ancestorDevice, ancestorInode: ancestorInode, leaseDevice: leaseDevice, leaseInode: leaseInode, fingerprint: fingerprint)
	}
	var fields: [String: Any] {
		return ["version": 1, "nonce": nonce, "directory_device": String(directoryDevice), "directory_inode": String(directoryInode),
			"ancestor_device": String(ancestorDevice), "ancestor_inode": String(ancestorInode),
			"lease_device": String(leaseDevice), "lease_inode": String(leaseInode), "binary_sha256": fingerprint]
	}
	func sourceReceipt(device: UInt64, inode: UInt64) throws -> Data {
		var value = fields; value["device"] = String(device); value["inode"] = String(inode)
		return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
	}
}

final class ManagedImageAlias {
	enum Failure: Error { case admission, file, cleanup; case operation(primary: Error, cleanup: Error) }
	private var native = ergopti_owned_image_alias()
	private var marker: Int32 = -1
	private var markerIdentity = stat()
	private var markerBytes = Data()
	private var markerWrittenBytes = Data()
	private var owner = false
	private var markerCloseDebt = false
	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	var receivingMarkerCloser: ((Int32) -> Int32)?
	#endif
	private func closeMarker() {
		guard marker >= 0 else { return }
		let descriptor = marker; marker = -1
		#if ERGOPTI_GUARDIAN_TEST_SUPPORT
		let status = receivingMarkerCloser?(descriptor) ?? Darwin.close(descriptor)
		#else
		let status = Darwin.close(descriptor)
		#endif
		if status != 0 { markerCloseDebt = true }
	}
	private(set) var proof: ManagedImageAliasProof!
	var executable: String {
		return withUnsafePointer(to: native.executable) { pointer in
			pointer.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
		}
	}
	static func fingerprint(_ descriptor: Int32, progress: () throws -> Void) throws -> String {
		var before = stat(), after = stat()
		guard fstat(descriptor, &before) == 0 else { throw Failure.admission }
		var digest = SHA256(), offset: off_t = 0
		while true {
			try progress()
			var buffer = [UInt8](repeating: 0, count: 65_536)
			let count = pread(descriptor, &buffer, buffer.count, offset)
			if count < 0 && errno == EINTR { continue }
			guard count >= 0 else { throw Failure.file }; if count == 0 { break }
			digest.update(data: Data(buffer.prefix(count))); offset += off_t(count)
		}
		guard fstat(descriptor, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
			before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
			before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
			before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.admission }
		return digest.finalize().map { String(format: "%02x", $0) }.joined()
	}
	static func acquire(retainedSource: Int32, directory: String, device: UInt64, inode: UInt64,
		fingerprint: String, register: (ManagedImageAlias) -> Void, progress: () throws -> Void) throws -> ManagedImageAlias {
		let value = ManagedImageAlias()
		register(value)
		let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
		value.owner = true
		let error = directory.withCString { directory in nonce.withCString {
			ergopti_image_alias_create(retainedSource, directory, $0, &value.native)
		} }
		guard error == 0, value.native.device == device, value.native.inode == inode else {
			let primary = Failure.admission
			guard ergopti_image_alias_retire(&value.native) == 0 else { throw Failure.operation(primary: primary, cleanup: Failure.cleanup) }
			value.owner = false; throw primary
		}
		do {
			guard try Self.fingerprint(retainedSource, progress: progress) == fingerprint else { throw Failure.admission }
			value.proof = ManagedImageAliasProof(nonce: nonce, directoryDevice: value.native.directory_device,
				directoryInode: value.native.directory_inode, ancestorDevice: value.native.ancestor_device, ancestorInode: value.native.ancestor_inode,
				leaseDevice: value.native.lease_device, leaseInode: value.native.lease_inode, fingerprint: fingerprint)
			value.markerBytes = try value.proof.sourceReceipt(device: device, inode: inode)
			value.marker = openat(value.native.lease_fd, "source.json", O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
			guard value.marker >= 0, fstat(value.marker, &value.markerIdentity) == 0 else { throw Failure.file }
			var offset = 0
			while offset < value.markerBytes.count {
				try progress()
				let count = value.markerBytes.withUnsafeBytes { Darwin.write(value.marker, $0.baseAddress!.advanced(by: offset), value.markerBytes.count - offset) }
				if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw Failure.file }; offset += count
				value.markerWrittenBytes = Data(value.markerBytes.prefix(offset))
			}
			guard fsync(value.marker) == 0 else { throw Failure.file }
			return value
		} catch let primary {
			do { try value.retire() } catch let cleanup { throw Failure.operation(primary: primary, cleanup: cleanup) }
			throw primary
		}
	}
	static func admit(proof: ManagedImageAliasProof, directory: String, device: UInt64, inode: UInt64,
		progress: () throws -> Void) throws -> ManagedImageAlias {
		let value = ManagedImageAlias(); value.proof = proof
		let error = directory.withCString { directory in proof.nonce.withCString {
			ergopti_image_alias_admit(directory, $0, proof.directoryDevice, proof.directoryInode, proof.ancestorDevice, proof.ancestorInode,
				proof.leaseDevice, proof.leaseInode, device, inode, &value.native)
		} }
		do {
			guard error == 0 else { throw Failure.admission }
			value.marker = openat(value.native.lease_fd, "source.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
			guard value.marker >= 0, fstat(value.marker, &value.markerIdentity) == 0,
				(value.markerIdentity.st_mode & S_IFMT) == S_IFREG, value.markerIdentity.st_uid == geteuid(),
				(value.markerIdentity.st_mode & 0o777) == 0o600, value.markerIdentity.st_nlink == 1 else { throw Failure.admission }
			value.markerBytes = try proof.sourceReceipt(device: device, inode: inode)
			var bytes = [UInt8](repeating: 0, count: value.markerBytes.count + 1)
			guard pread(value.marker, &bytes, bytes.count, 0) == value.markerBytes.count,
				Data(bytes.prefix(value.markerBytes.count)) == value.markerBytes,
				try Self.fingerprint(value.native.image_fd, progress: progress) == proof.fingerprint else { throw Failure.admission }
			value.markerWrittenBytes = value.markerBytes
			return value
		} catch let primary {
			do { try value.closeBorrow() } catch let cleanup { throw Failure.operation(primary: primary, cleanup: cleanup) }
			throw primary
		}
	}
	func closeBorrow() throws {
		guard !owner else { throw Failure.cleanup }
		closeMarker()
		let error = ergopti_image_alias_close(&native)
		guard !markerCloseDebt && error == 0 else { throw Failure.cleanup }
	}
	func retire() throws {
		guard owner else { throw Failure.cleanup }
		if marker >= 0 {
			var named = stat()
			var bytes = [UInt8](repeating: 0, count: markerWrittenBytes.count + 1)
			guard fstatat(native.lease_fd, "source.json", &named, AT_SYMLINK_NOFOLLOW) == 0,
				named.st_dev == markerIdentity.st_dev, named.st_ino == markerIdentity.st_ino,
				pread(marker, &bytes, bytes.count, 0) == markerWrittenBytes.count,
				Data(bytes.prefix(markerWrittenBytes.count)) == markerWrittenBytes,
				unlinkat(native.lease_fd, "source.json", 0) == 0 else { throw Failure.cleanup }
			closeMarker()
		}
		let error = ergopti_image_alias_retire(&native)
		guard !markerCloseDebt && error == 0 else { throw Failure.cleanup }; owner = false
	}
}
