// Sources/ErgoptiPlus/OwnedProgramNativeFixture.swift
// Debug-only real child fixtures; release builds expose no fixture role.

#if ERGOPTI_GUARDIAN_TEST_SUPPORT
import Darwin
import Foundation

enum OwnedProgramNativeFixture {
	static func run(arguments: [String]) -> Int32 {
		guard arguments.count >= 4 else { return 64 }
		let location = URL(fileURLWithPath: arguments[3])
		switch arguments[2] {
		case "argv":
			guard let data = try? JSONSerialization.data(withJSONObject: Array(arguments.dropFirst(4))) else { return 70 }
			do { try data.write(to: location); return 0 } catch { return 74 }
		case "flood-exit":
			let payload = Data("PRIVATE_OWNED_PROGRAM_STDOUT_STDERR_SENTINEL\n".utf8)
			var chunk = Data()
			while chunk.count < 4096 { chunk.append(payload) }
			chunk = Data(chunk.prefix(4096))
			for _ in 0..<8192 {
				for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
					let count = chunk.withUnsafeBytes { bytes in Darwin.write(descriptor, bytes.baseAddress!, bytes.count) }
					guard count == chunk.count else { return 74 }
				}
			}
			do { try Data("67108864".utf8).write(to: location); return 37 } catch { return 74 }
		case "parent-exit-live-child":
			guard let argv = duplicateCStringVector([
				arguments[0], ownedProgramFixtureFlag, "term-resistant-child", location.path
			]), let envp = duplicateProcessEnvironment() else { return 71 }
			defer {
				for case let pointer? in argv { free(pointer) }
				for case let pointer? in envp { free(pointer) }
			}
			var mutableArguments = argv
			var mutableEnvironment = envp
			var child: pid_t = 0
			let error = mutableArguments.withUnsafeMutableBufferPointer { argv in
				mutableEnvironment.withUnsafeMutableBufferPointer { envp in
					posix_spawn(&child, arguments[0], nil, nil, argv.baseAddress, envp.baseAddress)
				}
			}
			guard error == 0 else { return 71 }
			let ready = location.appendingPathComponent("child.json")
			let deadline = Date().addingTimeInterval(3)
			while !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline { usleep(1_000) }
			guard FileManager.default.fileExists(atPath: ready.path),
				let data = try? JSONSerialization.data(withJSONObject: ["pid": getpid(), "child": child])
			else { return 70 }
			do { try data.write(to: location.appendingPathComponent("leader.json"), options: .atomic); return 0 } catch { return 74 }
		case "term-resistant-child":
			_ = Darwin.signal(SIGTERM, SIG_IGN)
			_ = Darwin.signal(SIGHUP, SIG_IGN)
			guard let data = try? JSONSerialization.data(withJSONObject: ["pid": getpid(), "pgid": getpgrp()]) else { return 70 }
			do { try data.write(to: location.appendingPathComponent("child.json"), options: .atomic) } catch { return 74 }
			let stop = location.appendingPathComponent("fixture.stop")
			// An independent fixture stop and finite lifetime permit bounded cleanup
			// after an assertion fails; neither participates in the production proof.
			let deadline = Date().addingTimeInterval(30)
			let payload = Data(repeating: 80, count: 4096)
			while Date() < deadline && !FileManager.default.fileExists(atPath: stop.path) {
				for descriptor in [STDOUT_FILENO, STDERR_FILENO] {
					let count = payload.withUnsafeBytes { bytes in Darwin.write(descriptor, bytes.baseAddress!, bytes.count) }
					guard count == payload.count else { return 74 }
				}
				usleep(1_000)
			}
			return 0
		default: return 64
		}
	}
}
#endif
