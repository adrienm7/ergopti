// Unprivileged build artifact validation: it supplies no install, shipping or live runtime authority.
import Darwin
import Foundation
import Security

enum OwnedRuntimeBuildValidationEntry {
	static func validate(arguments: [String]) -> Bool {
		guard getuid() != 0, getuid() == geteuid(), arguments.count == 4,
			["--products", "--installer", "--installed-source"].contains(arguments[1]),
			arguments.allSatisfy({ !$0.contains("\0") }),
			arguments[2].hasPrefix("/"), arguments[3].hasPrefix("/") else { return false }
		do {
			let artifact = URL(fileURLWithPath: arguments[2]).resolvingSymlinksInPath()
			let leafURL = URL(fileURLWithPath: arguments[3]).resolvingSymlinksInPath()
			let leaf = try certificateBytes(at: leafURL)
			guard !leaf.isEmpty, leaf.count <= 65_536, SecCertificateCreateWithData(nil, leaf as CFData) != nil else { return false }
			let tree = try OwnedRuntimeInstallTree(root: arguments[1] == "--installed-source" ? artifact.deletingLastPathComponent() : artifact, protected: false)
			try tree.verify()
			if arguments[1] == "--products" { try OwnedRuntimeInstallOwner.validateSignedProductsForBuild(at: artifact, leaf: leaf) }
			else if arguments[1] == "--installer" { try OwnedRuntimeInstallOwner.validateSignedInstallerForBuild(at: artifact, leaf: leaf) }
			else { try OwnedRuntimeInstallOwner.validateSignedInstalledSourceForBuild(at: artifact, leaf: leaf) }
			try tree.verify()
			return tree.releaseOwnedDescriptors()
		} catch { return false }
	}
	private static func certificateBytes(at url: URL) throws -> Data {
		let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
		guard fd >= 0 else { throw OwnedRuntimeInstallFailure.source }
		var descriptorOwned = true
		defer { if descriptorOwned { close(fd) } }
		var before = stat()
		guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
			before.st_size > 0, before.st_size <= 65_536 else { throw OwnedRuntimeInstallFailure.source }
		var bytes = Data(count: Int(before.st_size))
		let count = bytes.withUnsafeMutableBytes { raw in pread(fd, raw.baseAddress!, raw.count, 0) }
		var after = stat()
		guard count == bytes.count, fstat(fd, &after) == 0,
			before.st_dev == after.st_dev, before.st_ino == after.st_ino,
			before.st_size == after.st_size, before.st_mode == after.st_mode,
			before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
			before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
			before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
			before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw OwnedRuntimeInstallFailure.source }
		descriptorOwned = false
		guard close(fd) == 0 else { throw OwnedRuntimeInstallFailure.cleanupPending }
		return bytes
	}
}
