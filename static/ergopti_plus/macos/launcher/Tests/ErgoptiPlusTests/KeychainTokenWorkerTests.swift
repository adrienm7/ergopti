// Tests/ErgoptiPlusTests/KeychainTokenWorkerTests.swift

import Foundation
import Security
import XCTest
@testable import ErgoptiPlus

private final class TestKeychainTokenStore: KeychainTokenStoring {
	var writeStatus: OSStatus = errSecSuccess
	var readStatus: OSStatus = errSecSuccess
	var deleteStatus: OSStatus = errSecSuccess
	var readSecret: Data?
	var writes: [(account: String, secret: Data)] = []
	var reads: [String] = []
	var deletes: [String] = []

	func write(account: String, secret: Data) -> OSStatus {
		writes.append((account, secret))
		return writeStatus
	}

	func read(account: String) -> (OSStatus, Data?) {
		reads.append(account)
		return (readStatus, readSecret)
	}

	func delete(account: String) -> OSStatus {
		deletes.append(account)
		return deleteStatus
	}
}

final class KeychainTokenWorkerTests: XCTestCase {
	func testWriteConsumesSecretFromInputAndNeverArgv() throws {
		let secret = "super-secret-token"
		let account = "entry-a"
		let arguments = ["/signed/ErgoptiPlus", kKeychainTokenWriteFlag, account]
		let store = TestKeychainTokenStore()

		let status = KeychainTokenWorker.run(
			arguments: arguments,
			input: Data(secret.utf8),
			store: store,
			writeOutput: { _ in XCTFail("write mode must not emit the token"); return false }
		)

		XCTAssertEqual(status, KeychainTokenWorkerExit.success.rawValue)
		XCTAssertFalse(arguments.contains(secret), "secret material must never enter argv")
		let write = try XCTUnwrap(store.writes.first)
		XCTAssertEqual(write.account, account)
		XCTAssertEqual(write.secret, Data(secret.utf8))
	}

	func testWriteRejectsMissingInputWithoutTouchingKeychain() {
		let store = TestKeychainTokenStore()
		let status = KeychainTokenWorker.run(
			arguments: ["ErgoptiPlus", kKeychainTokenWriteFlag, "entry-a"],
			input: nil,
			store: store,
			writeOutput: { _ in true }
		)
		XCTAssertEqual(status, KeychainTokenWorkerExit.inputFailure.rawValue)
		XCTAssertTrue(store.writes.isEmpty)
	}

	func testReadEmitsOnlyTheStoredSecret() {
		let store = TestKeychainTokenStore()
		store.readSecret = Data("resolved-secret".utf8)
		var output = Data()
		let status = KeychainTokenWorker.run(
			arguments: ["ErgoptiPlus", kKeychainTokenReadFlag, "entry-a"],
			input: nil,
			store: store,
			writeOutput: { output.append($0); return true }
		)
		XCTAssertEqual(status, KeychainTokenWorkerExit.success.rawValue)
		XCTAssertEqual(store.reads, ["entry-a"])
		XCTAssertEqual(String(data: output, encoding: .utf8), "resolved-secret")
	}

	func testDeleteTreatsMissingItemAsIdempotentSuccess() {
		let store = TestKeychainTokenStore()
		store.deleteStatus = errSecItemNotFound
		let status = KeychainTokenWorker.run(
			arguments: ["ErgoptiPlus", kKeychainTokenDeleteFlag, "entry-a"],
			input: nil,
			store: store,
			writeOutput: { _ in true }
		)
		XCTAssertEqual(status, KeychainTokenWorkerExit.success.rawValue)
		XCTAssertEqual(store.deletes, ["entry-a"])
	}

	func testInvocationRequiresExactlyOneNonSecretAccountArgument() {
		XCTAssertNil(KeychainTokenInvocation.parse(arguments: ["ErgoptiPlus", kKeychainTokenWriteFlag]))
		XCTAssertNil(KeychainTokenInvocation.parse(
			arguments: ["ErgoptiPlus", kKeychainTokenWriteFlag, "entry-a", "secret"]
		))
		XCTAssertFalse(KeychainTokenWorker.handles(arguments: ["ErgoptiPlus", "--unknown"]))
	}
}
