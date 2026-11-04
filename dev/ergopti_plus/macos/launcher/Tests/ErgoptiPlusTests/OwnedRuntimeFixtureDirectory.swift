// Tests/ErgoptiPlusTests/OwnedRuntimeFixtureDirectory.swift
// Physical temporary parents for owned-runtime custody fixtures.
import Darwin
import Foundation

enum OwnedRuntimeFixtureDirectory {
	enum Failure: Error { case unresolved }

	/// Creates a fresh directory under the POSIX realpath of the temporary root.
	/// Foundation's resolvingSymlinksInPath strips /private from an existing
	/// path, which leaves the /var alias that O_NOFOLLOW custody refuses as a
	/// symlink. Every component of the returned path is a real directory.
	static func create() throws -> URL {
		let resolved: UnsafeMutablePointer<CChar>? = FileManager.default.temporaryDirectory.withUnsafeFileSystemRepresentation { value in
			guard let value else { return nil }
			return Darwin.realpath(value, nil)
		}
		guard let resolved else { throw Failure.unresolved }
		defer { free(resolved) }
		let parent = URL(fileURLWithPath: String(cString: resolved), isDirectory: true).appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
		return parent
	}
}
