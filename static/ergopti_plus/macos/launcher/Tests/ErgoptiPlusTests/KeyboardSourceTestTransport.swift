// Tests/ErgoptiPlusTests/KeyboardSourceTestTransport.swift
// Test-only, lossless diagnostic transport. XCTest stdout remains its own owner.
import CryptoKit
import Darwin
import Foundation
import XCTest

private func tisSHA(_ data: Data) -> String {
	SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

final class KeyboardSourceTestSession: NSObject, XCTestObservation {
	struct Record: Codable {
		let index: Int
		let bytes: Int
		let sha256: String
		let closed: Bool
	}
	struct Start: Codable {
		let version: Int
		let session: String
		let producerPID: Int32
		let bundleSHA256: String
	}
	struct Manifest: Codable {
		let version: Int
		let session: String
		let producerPID: Int32
		let bundleSHA256: String
		let startSHA256: String
		let phase: String
		let enrolledCount: Int
		let records: [Record]
	}
	enum Refusal: Error { case source, publication, terminal }
	private let root: URL
	private let nonce: String
	private let pid: Int32
	private let bundle: URL
	private let start: Data
	private let closeDescriptor: (Int32) -> Int32
	private let lock = NSLock()
	private var pending: [Record?] = []
	private var refused = false
	private var finished = false
	private(set) var cleanupDebt = false

	init(root: URL, nonce: String, bundle: URL, pid: Int32,
		closeDescriptor: @escaping (Int32) -> Int32 = { Darwin.close($0) }) throws {
		guard root.isFileURL, root.path.hasPrefix("/"), nonce.utf8.count == 64,
			nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), pid > 0 else {
			throw Refusal.source
		}
		var state = stat()
		guard lstat(root.path, &state) == 0, (state.st_mode & S_IFMT) == S_IFDIR,
			state.st_uid == getuid(), (state.st_mode & 0o077) == 0,
			try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else { throw Refusal.source }
		self.root = root
		self.nonce = nonce
		self.pid = pid
		self.closeDescriptor = closeDescriptor
		let canonicalBundle = bundle.standardizedFileURL.resolvingSymlinksInPath()
		self.bundle = canonicalBundle
		self.start = try JSONEncoder().encode(Start(version: 1, session: nonce, producerPID: pid,
			bundleSHA256: tisSHA(Data(canonicalBundle.path.utf8))))
		super.init()
		guard publishFile("start.json", start) else { throw Refusal.publication }
	}

	// Write only a newly acquired descriptor. Close is attempted once; a failed
	// close ACK is retained debt, never permission to close a possibly reused fd.
	private func publishFile(_ name: String, _ data: Data) -> Bool {
		guard !cleanupDebt, getpid() == pid else { return false }
		let stage = root.appendingPathComponent("." + name + ".stage").path
		let target = root.appendingPathComponent(name).path
		let descriptor = open(stage, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
		guard descriptor >= 0 else { return false }
		var offset = 0
		let written = data.withUnsafeBytes { buffer -> Bool in
			guard let base = buffer.baseAddress else { return false }
			while offset < data.count {
				let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
				guard count > 0 else { return false }
				offset += count
			}
			return fsync(descriptor) == 0
		}
		let closed = closeDescriptor(descriptor) == 0
		if !closed { cleanupDebt = true; return false }
		guard written else {
			if unlink(stage) != 0 { cleanupDebt = true }
			return false
		}
		// link refuses an existing destination. No delete/replace fallback.
		guard link(stage, target) == 0 else {
			if unlink(stage) != 0 { cleanupDebt = true }
			return false
		}
		guard unlink(stage) == 0 else { cleanupDebt = true; return false }
		return true
	}

	private func refuse() {
		refused = true
		// A later invalid call must also invalidate an already published terminal.
		_ = publishFile("refusal.json", Data("{\"version\":1,\"refused\":true}".utf8))
	}

	func enroll() -> Int? {
		lock.lock(); defer { lock.unlock() }
		guard !refused, !finished, !cleanupDebt, getpid() == pid, pending.count < 64 else {
			refuse(); return nil
		}
		pending.append(nil)
		return pending.count
	}

	func publish(_ index: Int, _ data: Data) -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard !refused, !finished, !cleanupDebt, getpid() == pid,
			index > 0, index <= pending.count, pending[index - 1] == nil,
			data.count > 0, data.count <= 2_097_152 else { refuse(); return false }
		guard publishFile(String(format: "record-%06d.dat", index), data) else { refuse(); return false }
		pending[index - 1] = Record(index: index, bytes: data.count, sha256: tisSHA(data), closed: true)
		return true
	}

	func finish(bundle: URL, pid: Int32) -> Bool {
		lock.lock(); defer { lock.unlock() }
		guard !refused, !finished, !cleanupDebt, pid == self.pid, getpid() == self.pid,
			bundle.standardizedFileURL.resolvingSymlinksInPath() == self.bundle,
			!pending.isEmpty, pending.allSatisfy({ $0 != nil }) else { refuse(); return false }
		finished = true
		let manifest = Manifest(version: 1, session: nonce, producerPID: self.pid,
			bundleSHA256: tisSHA(Data(self.bundle.path.utf8)), startSHA256: tisSHA(start),
			phase: "closed", enrolledCount: pending.count, records: pending.compactMap { $0 })
		guard let data = try? JSONEncoder().encode(manifest), publishFile("manifest.json", data) else {
			refuse(); return false
		}
		return true
	}

	func testBundleDidFinish(_ testBundle: Bundle) {
		if !finish(bundle: testBundle.bundleURL, pid: ProcessInfo.processInfo.processIdentifier) {
			XCTFail("TIS diagnostic terminal publication was refused")
		}
	}
}

enum KeyboardSourceTestTransport {
	// Strong process-local ownership; forked children cannot inherit admission.
	private static let session: KeyboardSourceTestSession? = {
		let environment = ProcessInfo.processInfo.environment
		guard let path = environment["ERGOPTI_TIS_EVIDENCE_DIR"],
			let nonce = environment["ERGOPTI_TIS_EVIDENCE_SESSION"] else { return nil }
		guard let owner = try? KeyboardSourceTestSession(root: URL(fileURLWithPath: path), nonce: nonce,
			bundle: Bundle(for: KeyboardSourceTestDiagnosticsTests.self).bundleURL,
			pid: ProcessInfo.processInfo.processIdentifier) else { return nil }
		XCTestObservationCenter.shared.addTestObserver(owner)
		return owner
	}()
	static func enroll() -> Int? {
		guard let index = session?.enroll() else { XCTFail("TIS diagnostic enrollment was refused"); return nil }
		return index
	}
	static func publish(_ index: Int, _ data: Data) -> Bool { session?.publish(index, data) == true }
}

final class KeyboardSourceTestTransportTests: XCTestCase {
	private func fixture(_ body: (KeyboardSourceTestSession, URL) throws -> Void) throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: root) }
		let owner = try KeyboardSourceTestSession(root: root, nonce: String(repeating: "a", count: 64),
			bundle: Bundle(for: Self.self).bundleURL, pid: getpid())
		try body(owner, root)
	}

	func testExactLargeEncoderBytesCloseBeforeTerminalPublication() throws {
		try fixture { owner, root in
			let index = try XCTUnwrap(owner.enroll())
			let recorder = KeyboardSourceTestDiagnostics("controlled.é", enroll: false)
			for _ in 0..<64 {
				recorder.append(.init(phase: "controlled", uptime: 1, status: -50,
					original: nil, target: nil, current: nil,
					snapshotID: .bounded(String(repeating: "é", count: 512)), keyboardType: nil, unicodeDataBytes: nil))
			}
			let json = try JSONEncoder().encode(recorder.receipt())
			var record = Data("TIS_TEST_EVIDENCE ".utf8); record.append(json); record.append(0x0A)
			XCTAssertGreaterThan(record.count, 4_096)
			XCTAssertTrue(owner.publish(index, record))
			XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("record-000001.dat")), record)
			XCTAssertFalse(owner.cleanupDebt)
			XCTAssertTrue(owner.finish(bundle: Bundle(for: Self.self).bundleURL, pid: getpid()))
			let terminal = try JSONDecoder().decode(KeyboardSourceTestSession.Manifest.self,
				from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
			XCTAssertEqual(terminal.records.first?.sha256, tisSHA(record))
			XCTAssertEqual(terminal.records.first?.bytes, record.count)
			XCTAssertEqual(terminal.enrolledCount, 1)
		}
	}

	func testActualObserverCallbackPublishesOnlyItsExactBundle() throws {
		try fixture { owner, root in
			let index = try XCTUnwrap(owner.enroll())
			let recorder = KeyboardSourceTestDiagnostics("controlled.callback", enroll: false)
			var bytes = Data()
			KeyboardSourceTestDiagnostics.writeRecord(encode: { try JSONEncoder().encode(recorder.receipt()) },
				write: { bytes = $0 })
			XCTAssertTrue(owner.publish(index, bytes))
			owner.testBundleDidFinish(Bundle(for: Self.self))
			XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
			XCTAssertFalse(owner.finish(bundle: Bundle(for: Self.self).bundleURL, pid: getpid()))
			XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("refusal.json").path))
		}
	}

	func testLastUnemittedEnrollmentCannotPublishTerminal() throws {
		try fixture { owner, root in
			XCTAssertNotNil(owner.enroll())
			XCTAssertFalse(owner.finish(bundle: Bundle(for: Self.self).bundleURL, pid: getpid()))
			XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
		}
	}

	func testForeignBundleAndDuplicatePublicationRefuseWithoutReplacingBytes() throws {
		try fixture { owner, root in
			let index = try XCTUnwrap(owner.enroll())
			let bytes = Data("controlled complete record\n".utf8)
			XCTAssertTrue(owner.publish(index, bytes))
			XCTAssertFalse(owner.publish(index, Data("foreign".utf8)))
			XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("record-000001.dat")), bytes)
			XCTAssertFalse(owner.finish(bundle: Bundle(for: Self.self).bundleURL, pid: getpid()))
		}
		try fixture { owner, _ in
			XCTAssertNotNil(owner.enroll())
			XCTAssertFalse(owner.finish(bundle: URL(fileURLWithPath: "/foreign.bundle"), pid: getpid()))
		}
	}

	func testExistingNativeDestinationIsNeverOverwritten() throws {
		try fixture { owner, root in
			let index = try XCTUnwrap(owner.enroll())
			let target = root.appendingPathComponent("record-000001.dat")
			let foreign = Data("foreign bytes".utf8)
			try foreign.write(to: target, options: .withoutOverwriting)
			XCTAssertFalse(owner.publish(index, Data("owned".utf8)))
			XCTAssertEqual(try Data(contentsOf: target), foreign)
			XCTAssertNil(owner.enroll())
		}
	}
	func testZeroRecordsAndForeignPIDCannotPublishTerminal() throws {
		try fixture { owner, root in
			XCTAssertFalse(owner.finish(bundle: Bundle(for: Self.self).bundleURL, pid: getpid()))
			XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
		}
		try fixture { owner, _ in
			let index = try XCTUnwrap(owner.enroll())
			XCTAssertTrue(owner.publish(index, Data("controlled\n".utf8)))
			XCTAssertFalse(owner.finish(bundle: Bundle(for: Self.self).bundleURL, pid: getpid() + 1))
		}
	}

	func testForeignNativePIDCannotAcquireAnyPublicationFile() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: root) }
		XCTAssertThrowsError(try KeyboardSourceTestSession(root: root, nonce: String(repeating: "a", count: 64),
			bundle: Bundle(for: Self.self).bundleURL, pid: getpid() + 1))
		XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
	}

	func testNativeCloseRefusalKeepsDebtAndBlocksSuccessor() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: root) }
		var closes = 0
		let owner = try KeyboardSourceTestSession(root: root, nonce: String(repeating: "a", count: 64),
			bundle: Bundle(for: Self.self).bundleURL, pid: getpid(), closeDescriptor: { descriptor in
				let native = Darwin.close(descriptor)
				closes += 1
				return closes == 2 ? -1 : native
			})
		let index = try XCTUnwrap(owner.enroll())
		XCTAssertFalse(owner.publish(index, Data("owned\n".utf8)))
		XCTAssertTrue(owner.cleanupDebt)
		XCTAssertNil(owner.enroll())
		XCTAssertFalse(owner.finish(bundle: Bundle(for: Self.self).bundleURL, pid: getpid()))
		XCTAssertEqual(closes, 2, "A refused close is never retried on a reused descriptor")
		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path))
	}

}
