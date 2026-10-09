import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

/// Actual private filesystem controls with an injected scheduling clock; native execution is required.
final class LeaseDiagnosticNextObservationTests: XCTestCase {
	private let inner = #"{"schema":1,"role":"inner","boundary":"outer-silent","command":"none","cli":"none","stopping":false,"gateHeld":false,"deadlineArmed":false,"fence":"exhausted","exit":"inner-failed"}"#
	private let outer_failure = #"{"schema":1,"role":"outer","boundary":"private-deadline","command":"heartbeat","cli":"none","stopping":false,"gateHeld":true,"deadlineArmed":true,"fence":"recovered","exit":"inner-failed"}"#
	private let outer_recovery = #"{"schema":1,"role":"outer","boundary":"private-deadline","command":"heartbeat","cli":"none","stopping":true,"gateHeld":false,"deadlineArmed":false,"fence":"recovered","exit":"success"}"#

	private func record(_ text: String) throws -> LeaseTerminalExport {
		try XCTUnwrap(LeaseTerminalExport.decode(Data(text.utf8)))
	}

	private func fixture(_ body: (URL) throws -> Void) throws {
		let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
			.appendingPathComponent("lease-next-" + UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
			attributes: [.posixPermissions: NSNumber(value: 0o700)])
		defer { try? FileManager.default.removeItem(at: directory) }
		try body(directory)
	}

	private func file(_ directory: URL, _ role: String = "outer") -> URL {
		directory.appendingPathComponent("remap-lease-diagnostic-" + role + ".json")
	}

	private func put(_ data: Data, at url: URL, mode: mode_t = 0o600) throws {
		let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_NONBLOCK, mode)
		XCTAssertGreaterThanOrEqual(descriptor, 0)
		guard descriptor >= 0 else { return }
		defer { XCTAssertEqual(Darwin.close(descriptor), 0) }
		XCTAssertEqual(Darwin.fchmod(descriptor, mode), 0)
		XCTAssertEqual(data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }, data.count)
		XCTAssertEqual(Darwin.fsync(descriptor), 0)
	}

	private func identity(_ url: URL) throws -> stat {
		var value = stat()
		XCTAssertEqual(Darwin.lstat(url.path, &value), 0)
		return value
	}

	private func timeoutFrames(_ store: RemapLeaseDiagnosticStore,
		armed: (() -> Void)? = nil, sleepAction: (() -> Void)? = nil) -> [LeaseDiagnosticNextFrame] {
		var now: TimeInterval = 0
		var frames: [LeaseDiagnosticNextFrame] = []
		XCTAssertTrue(store.observeNext(emit: { frame in
			frames.append(frame)
			if frame.phase == .armed { armed?() }
			return true
		}, uptime: { now }, sleep: { _ in sleepAction?(); now = 30 }))
		return frames
	}

	func testUnchangedOneAndTwoRolesNeverBecomeNew() throws {
		for both in [false, true] {
			try fixture { directory in
				try put(Data(outer_failure.utf8), at: file(directory))
				if both { try put(Data(inner.utf8), at: file(directory, "inner")) }
				let frames = timeoutFrames(RemapLeaseDiagnosticStore(testingDirectory: directory))
				XCTAssertEqual(frames.map { $0.phase }, [.armed, .unobserved])
				XCTAssertTrue(frames.allSatisfy { $0.records.isEmpty })
			}
		}
	}

	func testChangedFieldsOnSameVnodeNeverBecomeNew() throws {
		try fixture { directory in
			try put(Data(outer_failure.utf8), at: file(directory))
			let before = try identity(file(directory))
			let frames = timeoutFrames(RemapLeaseDiagnosticStore(testingDirectory: directory), armed: {
				do { try self.put(Data(self.outer_recovery.utf8), at: self.file(directory)) }
				catch { XCTFail("Controlled in-place write failed") }
			})
			let after = try identity(file(directory))
			XCTAssertEqual(before.st_ino, after.st_ino)
			XCTAssertEqual(frames.map { $0.phase }, [.armed, .unobserved])
		}
	}

	func testAtomicIdenticalPublicationChangesVnodeAndIsObserved() throws {
		try fixture { directory in
			try put(Data(outer_failure.utf8), at: file(directory))
			let before = try identity(file(directory)), directoryBefore = try identity(directory)
			let value = try record(outer_failure)
			let store = RemapLeaseDiagnosticStore(testingDirectory: directory)
			let frames = timeoutFrames(store, armed: {
				XCTAssertTrue(store.retain(value))
				do { try FileManager.default.setAttributes(
					[.modificationDate: Date(timeIntervalSince1970: TimeInterval(directoryBefore.st_mtimespec.tv_sec) + 2)],
					ofItemAtPath: directory.path) }
				catch { XCTFail("Controlled directory metadata change failed") }
			})
			let after = try identity(file(directory)), directoryAfter = try identity(directory)
			XCTAssertNotEqual(before.st_ino, after.st_ino)
			XCTAssertTrue(directoryBefore.st_mtimespec.tv_nsec != directoryAfter.st_mtimespec.tv_nsec
				|| directoryBefore.st_mtimespec.tv_sec != directoryAfter.st_mtimespec.tv_sec
				|| directoryBefore.st_ctimespec.tv_nsec != directoryAfter.st_ctimespec.tv_nsec
				|| directoryBefore.st_ctimespec.tv_sec != directoryAfter.st_ctimespec.tv_sec)
			XCTAssertEqual(frames.map { $0.phase }, [.armed, .observed])
			XCTAssertEqual(frames.last?.records.first?.encodedRecord(), value.encodedRecord())
		}
	}

	func testAbsentRoleAndEmptyBaselinePermitOneNewRecord() throws {
		for role in [LeaseTerminalRole.inner, .outer] {
			try fixture { directory in
				if role == .inner { try put(Data(outer_failure.utf8), at: file(directory)) }
				let store = RemapLeaseDiagnosticStore(testingDirectory: directory)
				let value = try record(role == .inner ? inner : outer_failure)
				let frames = timeoutFrames(store, armed: { XCTAssertTrue(store.retain(value)) })
				XCTAssertEqual(frames.map { $0.phase }, [.armed, .observed])
				XCTAssertEqual(frames.last?.records.count, 1)
				XCTAssertEqual(frames.last?.records.first?.role, role)
			}
		}
	}

	func testFirstTypedFailureIsNotReplacedDuringFinalEmission() throws {
		try fixture { directory in
			try put(Data(outer_recovery.utf8), at: file(directory))
			let store = RemapLeaseDiagnosticStore(testingDirectory: directory)
			let failure = try record(outer_failure), recovery = try record(outer_recovery), later = try record(inner)
			var frames: [LeaseDiagnosticNextFrame] = []
			var sleeps = 0
			XCTAssertTrue(store.observeNext(emit: { frame in
				frames.append(frame)
				if frame.phase == .armed { XCTAssertTrue(store.retain(failure)) }
				if frame.phase == .observed {
					XCTAssertTrue(store.retain(recovery)); XCTAssertTrue(store.retain(later))
				}
				return true
			}, uptime: { 0 }, sleep: { _ in sleeps += 1 }))
			XCTAssertEqual(sleeps, 0)
			XCTAssertEqual(frames.last?.records.first?.encodedRecord(), failure.encodedRecord())
			XCTAssertEqual(frames.last?.records.count, 1)
		}
	}

	func testBothNewRolesStillExportExactlyOneObservedRole() throws {
		try fixture { directory in
			let store = RemapLeaseDiagnosticStore(testingDirectory: directory)
			let first = try record(inner), second = try record(outer_failure)
			let frames = timeoutFrames(store, armed: {
				XCTAssertTrue(store.retain(first)); XCTAssertTrue(store.retain(second))
			})
			XCTAssertEqual(frames.last?.phase, .observed)
			XCTAssertEqual(frames.last?.records.count, 1)
			XCTAssertEqual(frames.last?.scope, "first-observed-new-record")
			XCTAssertEqual(frames.last?.currentness, "unknown")
		}
	}

	func testInvalidBaselineRefusesArmingWithoutRepair() throws {
		let inputs = [Data("{".utf8), Data((String(outer_failure.dropLast()) + ",\"token\":\"synthetic\"}").utf8),
			Data(inner.utf8)]
		for bytes in inputs {
			try fixture { directory in
				try put(bytes, at: file(directory))
				let frames = timeoutFrames(RemapLeaseDiagnosticStore(testingDirectory: directory))
				XCTAssertEqual(frames.map { $0.phase }, [.unobserved])
				XCTAssertEqual(try Data(contentsOf: file(directory)), bytes)
			}
		}
		for mode in [mode_t(0o644), mode_t(0o1600)] {
			try fixture { directory in
				try put(Data(outer_failure.utf8), at: file(directory), mode: mode)
				let frames = timeoutFrames(RemapLeaseDiagnosticStore(testingDirectory: directory))
				XCTAssertEqual(frames.map { $0.phase }, [.unobserved])
				XCTAssertEqual(try identity(file(directory)).st_mode & 0o7777, mode)
			}
		}
	}

	func testInvalidNewRecordsNeverLatchAndLaterValidCanRecover() throws {
		let inputs = [Data("{".utf8), Data([0xff]), Data((outer_failure + "suffix").utf8),
			Data((String(outer_failure.dropLast()) + ",\"path\":\"synthetic\"}").utf8), Data(inner.utf8)]
		for bytes in inputs {
			try fixture { directory in
				let store = RemapLeaseDiagnosticStore(testingDirectory: directory)
				let frames = timeoutFrames(store, armed: {
					do { try self.put(bytes, at: self.file(directory)) }
					catch { XCTFail("Controlled invalid fixture write failed") }
				})
				XCTAssertEqual(frames.map { $0.phase }, [.armed, .unobserved])
				XCTAssertEqual(try Data(contentsOf: file(directory)), bytes)
			}
		}
		try fixture { directory in
			let store = RemapLeaseDiagnosticStore(testingDirectory: directory)
			let valid = try record(outer_failure)
			var frames: [LeaseDiagnosticNextFrame] = [], now: TimeInterval = 0
			XCTAssertTrue(store.observeNext(emit: { frame in
				frames.append(frame)
				if frame.phase == .armed {
					do { try self.put(Data("{".utf8), at: self.file(directory)) }
					catch { XCTFail("Controlled partial write failed") }
				}
				return true
			}, uptime: { now }, sleep: { _ in XCTAssertTrue(store.retain(valid)); now = 0.05 }))
			XCTAssertEqual(frames.map { $0.phase }, [.armed, .observed])
		}
	}

	func testAliasedAndUnsupportedCandidatesAreNotReadOrRepaired() throws {
		for kind in ["symlink", "hardlink", "fifo", "oversize", "mode"] {
			try fixture { directory in
				let target = directory.appendingPathComponent("fixture-target")
				try put(Data(outer_failure.utf8), at: target)
				var reads = 0
				let store = RemapLeaseDiagnosticStore(testingDirectory: directory, afterSingleRead: { _ in reads += 1 })
				let frames = timeoutFrames(store, armed: {
					let name = self.file(directory).path
					switch kind {
					case "symlink": XCTAssertEqual(Darwin.symlink(target.path, name), 0)
					case "hardlink": XCTAssertEqual(Darwin.link(target.path, name), 0)
					case "fifo": XCTAssertEqual(Darwin.mkfifo(name, 0o600), 0)
					default:
						do { try self.put(kind == "oversize" ? Data(repeating: 65, count: 513) : Data(self.outer_failure.utf8),
							at: self.file(directory), mode: kind == "mode" ? 0o644 : 0o600) }
						catch { XCTFail("Controlled unsupported fixture write failed") }
					}
				})
				XCTAssertEqual(frames.map { $0.phase }, [.armed, .unobserved])
				XCTAssertEqual(reads, 0)
				XCTAssertEqual(try Data(contentsOf: target), Data(outer_failure.utf8))
			}
		}
	}

	func testFileReplacementAfterReadRejectsThatCut() throws {
		try fixture { directory in
			let publisher = RemapLeaseDiagnosticStore(testingDirectory: directory)
			let value = try record(outer_failure)
			var armed = false, reads = 0
			let store = RemapLeaseDiagnosticStore(testingDirectory: directory, afterSingleRead: { _ in
				if armed { reads += 1; XCTAssertTrue(publisher.retain(value)) }
			})
			let frames = timeoutFrames(store, armed: { armed = true; XCTAssertTrue(publisher.retain(value)) })
			XCTAssertEqual(reads, 1)
			XCTAssertEqual(frames.map { $0.phase }, [.armed, .unobserved])
		}
	}

	func testNamespaceReplacementAndAncestorAliasRefuseReadCut() throws {
		for alias in [false, true] {
			try fixture { parent in
				let directory = parent.appendingPathComponent("records", isDirectory: true)
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
					attributes: [.posixPermissions: NSNumber(value: 0o700)])
				let parked = parent.appendingPathComponent("parked", isDirectory: true)
				let publisher = RemapLeaseDiagnosticStore(testingDirectory: directory)
				let value = try record(outer_failure)
				var armed = false, reads = 0
				let store = RemapLeaseDiagnosticStore(testingDirectory: directory, afterSingleRead: { _ in
					guard armed else { return }; reads += 1
					do {
						try FileManager.default.moveItem(at: directory, to: parked)
						if alias { try FileManager.default.createSymbolicLink(atPath: directory.path, withDestinationPath: parked.path) }
						else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
							attributes: [.posixPermissions: NSNumber(value: 0o700)]) }
					} catch { XCTFail("Controlled namespace replacement failed") }
				})
				let frames = timeoutFrames(store, armed: { armed = true; XCTAssertTrue(publisher.retain(value)) })
				XCTAssertEqual(reads, 1)
				XCTAssertEqual(frames.map { $0.phase }, [.armed, .unobserved])
			}
		}
	}

	func testArmedAndObservedOutputFailuresDoNotRetryOrResample() throws {
		for phase in [LeaseDiagnosticNextPhase.armed, .observed] {
			try fixture { directory in
				try put(Data(outer_failure.utf8), at: file(directory))
				let publisher = RemapLeaseDiagnosticStore(testingDirectory: directory)
				let value = try record(outer_recovery)
				var emissions = 0, reads = 0, sleeps = 0
				let store = RemapLeaseDiagnosticStore(testingDirectory: directory, afterSingleRead: { _ in reads += 1 })
				XCTAssertFalse(store.observeNext(emit: { frame in
					emissions += 1
					if frame.phase == .armed && phase == .observed { XCTAssertTrue(publisher.retain(value)) }
					return frame.phase != phase
				}, uptime: { 0 }, sleep: { _ in sleeps += 1 }))
				XCTAssertEqual(emissions, phase == .armed ? 1 : 2)
				XCTAssertEqual(reads, phase == .armed ? 1 : 2)
				XCTAssertEqual(sleeps, 0)
			}
		}
	}

	func testArmedCallbackAndReadTimeConsumeDeadline() throws {
		for duringRead in [false, true] {
			try fixture { directory in
				let publisher = RemapLeaseDiagnosticStore(testingDirectory: directory)
				let value = try record(outer_failure)
				var now: TimeInterval = 0, armed = false
				let store = RemapLeaseDiagnosticStore(testingDirectory: directory, afterSingleRead: { _ in
					if armed && duringRead { now = 30 }
				})
				var phases: [LeaseDiagnosticNextPhase] = []
				XCTAssertTrue(store.observeNext(emit: { frame in
					phases.append(frame.phase)
					if frame.phase == .armed {
						armed = true; XCTAssertTrue(publisher.retain(value))
						if !duringRead { now = 30 }
					}
					return true
				}, uptime: { now }, sleep: { _ in XCTFail("No deadline sleep permitted") }))
				XCTAssertEqual(phases, [.armed, .unobserved])
			}
		}
	}

	func testStalledBackwardsAndNonfiniteClocksAreFinite() throws {
		for kind in ["stalled", "backward", "nan", "infinite", "initial"] {
			try fixture { directory in
				var now: TimeInterval = kind == "initial" ? .nan : 1
				try put(Data(outer_failure.utf8), at: file(directory))
				var reads = 0, sleeps = 0, phases: [LeaseDiagnosticNextPhase] = []
				let store = RemapLeaseDiagnosticStore(testingDirectory: directory, afterSingleRead: { _ in reads += 1 })
				XCTAssertTrue(store.observeNext(emit: { frame in
					phases.append(frame.phase)
					if frame.phase == .armed {
						if kind == "backward" { now = 0 }
						if kind == "nan" { now = .nan }
						if kind == "infinite" { now = .infinity }
					}
					return true
				}, uptime: { now }, sleep: { duration in sleeps += 1; XCTAssertLessThanOrEqual(duration, 50_000) }))
				XCTAssertEqual(phases.last, .unobserved)
				XCTAssertEqual(sleeps, kind == "stalled" ? 599 : 0)
				XCTAssertEqual(reads, kind == "stalled" ? 601 : 1)
				XCTAssertLessThanOrEqual(reads - 1, 600)
			}
		}
	}

	func testSleepIsCappedToRemainingDeadline() throws {
		try fixture { directory in
			var now: TimeInterval = 0, durations: [useconds_t] = []
			XCTAssertTrue(RemapLeaseDiagnosticStore(testingDirectory: directory).observeNext(emit: { _ in true },
				uptime: { now }, sleep: { duration in
					durations.append(duration)
					now = durations.count == 1 ? 29.99 : 30
				}))
			XCTAssertEqual(durations.count, 2)
			XCTAssertEqual(durations.first, 50_000)
			XCTAssertLessThanOrEqual(try XCTUnwrap(durations.last), 10_000)
			XCTAssertGreaterThan(try XCTUnwrap(durations.last), 0)
		}
	}

	func testFramesAreClosedAndInvalidArgvRefusesBeforeEffects() throws {
		let value = try record(outer_failure)
		for phase in [LeaseDiagnosticNextPhase.armed, .observed, .unobserved] {
			let frame = LeaseDiagnosticNextFrame(phase: phase, records: phase == .observed ? [value] : [])
			let data = try XCTUnwrap(frame.encodedFrame())
			XCTAssertLessThanOrEqual(data.count, 2048)
			let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
			XCTAssertEqual(Set(object.keys), Set(["schema", "scope", "phase", "currentness", "records"]))
			XCTAssertEqual(object["schema"] as? Int, 1)
			XCTAssertEqual(object["scope"] as? String, "first-observed-new-record")
			XCTAssertEqual(object["currentness"] as? String, "unknown")
		}
		XCTAssertNil(LeaseDiagnosticNextFrame(phase: .armed, records: [value]).encodedFrame())
		XCTAssertNil(LeaseDiagnosticNextFrame(phase: .observed, records: []).encodedFrame())
		XCTAssertNil(LeaseDiagnosticNextFrame(phase: .observed, records: [value, value]).encodedFrame())
		for extra in ["synthetic-path", "--observe-next-remap-lease-diagnostics"] {
			let argv = ["launcher", "--observe-next-remap-lease-diagnostics", extra]
			XCTAssertTrue(KarabinerLeaseWorker.handles(arguments: argv))
			XCTAssertEqual(KarabinerLeaseWorker.run(arguments: argv), LeaseWorkerExit.invalidArguments.rawValue)
		}
		XCTAssertFalse(KarabinerLeaseWorker.handles(arguments: ["launcher", "--observe-next-remap-lease-unknown"]))
	}

	func testTrueAncestorAliasPreservesLeafIdentitiesButRefusesPublication() throws {
		try fixture { top in
			let parent = top.appendingPathComponent("parent", isDirectory: true)
			let parked = top.appendingPathComponent("parked", isDirectory: true)
			let directory = parent.appendingPathComponent("records", isDirectory: true)
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
				attributes: [.posixPermissions: NSNumber(value: 0o700)])
			let publisher = RemapLeaseDiagnosticStore(testingDirectory: directory)
			let value = try record(outer_failure)
			var armed = false, reads = 0
			let store = RemapLeaseDiagnosticStore(testingDirectory: directory, afterSingleRead: { _ in
				guard armed else { return }; reads += 1
				do {
					let beforeDirectory = try self.identity(directory), beforeFile = try self.identity(self.file(directory))
					try FileManager.default.moveItem(at: parent, to: parked)
					try FileManager.default.createSymbolicLink(atPath: parent.path, withDestinationPath: parked.path)
					XCTAssertEqual(beforeDirectory.st_ino, try self.identity(directory).st_ino)
					XCTAssertEqual(beforeFile.st_ino, try self.identity(self.file(directory)).st_ino)
				} catch { XCTFail("Controlled ancestor alias failed") }
			})
			let frames = timeoutFrames(store, armed: { armed = true; XCTAssertTrue(publisher.retain(value)) })
			XCTAssertEqual(reads, 1)
			XCTAssertEqual(frames.map { $0.phase }, [.armed, .unobserved])
		}
	}

	func testMissingAndNonprivateBaselineAreNotCreatedOrRepaired() throws {
		try fixture { directory in
			let missing = directory.appendingPathComponent("absent", isDirectory: true)
			let frames = timeoutFrames(RemapLeaseDiagnosticStore(testingDirectory: missing))
			XCTAssertEqual(frames.map { $0.phase }, [.unobserved])
			XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
			XCTAssertEqual(Darwin.chmod(directory.path, 0o755), 0)
			let refused = timeoutFrames(RemapLeaseDiagnosticStore(testingDirectory: directory))
			XCTAssertEqual(refused.map { $0.phase }, [.unobserved])
			XCTAssertEqual(try identity(directory).st_mode & 0o7777, mode_t(0o755))
		}
	}

	func testBaselineReadCompletesBeforeArmingAndDoesNotPollOnEmissionFailure() throws {
		try fixture { directory in
			try put(Data(outer_failure.utf8), at: file(directory))
			var reads = 0
			let store = RemapLeaseDiagnosticStore(testingDirectory: directory, afterSingleRead: { _ in reads += 1 })
			XCTAssertFalse(store.observeNext(emit: { frame in
				XCTAssertEqual(frame.phase, .armed)
				XCTAssertEqual(reads, 1)
				return false
			}, uptime: { 0 }, sleep: { _ in XCTFail("Failed handshake must not wait") }))
			XCTAssertEqual(reads, 1)
		}
	}
}
