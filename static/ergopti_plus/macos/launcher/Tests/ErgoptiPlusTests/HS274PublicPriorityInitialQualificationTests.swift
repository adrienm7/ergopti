// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274PublicPriorityInitialQualificationTests.swift
//
// One public SDK subscription qualifies an initial sample and its retirement.
// Capability classes never authorize production capture or imply session unlock.

import Darwin
import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testActualPublicPrioritySubscriptionInitialSampleAndRetirement() throws {
		try fixture { root in
			struct Cut {
				let original: URL
				let stamp: [Int64]
				let bytes: Data
			}
			func capture(_ original: URL) throws -> Cut {
				let descriptor = open(original.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
				guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
				let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
				defer { try? handle.close() }
				func stamp() throws -> [Int64] {
					var info = stat()
					guard fstat(descriptor, &info) == 0,
						info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid(),
						info.st_size > 0, info.st_size <= 65_536 else { throw CocoaError(.fileReadCorruptFile) }
					return [Int64(info.st_dev), Int64(bitPattern: UInt64(info.st_ino)), Int64(info.st_uid), Int64(info.st_mode),
						Int64(info.st_size), Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
						Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
				}
				let before = try stamp()
				let bytes = try handle.read(upToCount: 65_537) ?? Data()
				guard before == (try stamp()), Int64(bytes.count) == before[4] else {
					throw CocoaError(.fileReadCorruptFile)
				}
				return Cut(original: original, stamp: before, bytes: bytes)
			}
			let names = ["hs274-public-priority-initial-test.cpp", "hs274-priority-initial-policy.hpp"]
			let cuts = try names.map { try capture(source($0).resolvingSymlinksInPath()) }
			for (name, cut) in zip(names, cuts) {
				try cut.bytes.write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
			}
			let input = root.appendingPathComponent(names[0])
			let executable = root.appendingPathComponent("public-priority-initial")
			// This is one Guardian worker, including clang, controls and observation.
			// Fixed positional arguments keep paths out of the shell command text.
			let command = "/usr/bin/xcrun clang++ -std=c++17 -Wall -Wextra -Werror -pedantic "
				+ "-framework CoreFoundation -framework IOKit \"$1\" -o \"$2\" && exec \"$2\" --qualify"
			let receipt = try run(URL(fileURLWithPath: "/bin/sh"),
				["-c", command, "priority-sdk", input.path, executable.path], root: root)
			for cut in cuts {
				let current = try capture(cut.original)
				XCTAssertEqual(current.stamp, cut.stamp)
				XCTAssertEqual(current.bytes, cut.bytes)
			}
			XCTAssertEqual(receipt.status, 0,
				"Public priority SDK qualification refused; " + String(reflecting: receipt.stderr.prefix(4096)))
			XCTAssertTrue(receipt.stderr.isEmpty)
			let prefix = "PASS public priority initial controls assertions=35; native_framework_calls=unexecuted\n"
			let suffix = "; subscription_retired=observed; physical_transitions=unexecuted; session_lock_authority=unresolved\n"
			let allowed = Set(["cpu_inactive", "cpu_without_graphics", "graphics_capable"].map {
				prefix + "PASS public priority initial class=" + $0 + suffix
			})
			XCTAssertTrue(allowed.contains(receipt.stdout), "Closed genuine initial classification and retirement required")
		}
	}
}
