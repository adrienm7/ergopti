// Sources/ErgoptiPlus/KeychainTokenWorker.swift

// ==============================================================================
// MODULE: Keychain Token Worker
// DESCRIPTION:
// Provides three headless modes in the signed ErgoptiPlus executable for
// generic-password write, read, and delete operations. Secret bytes cross only
// stdin/stdout; command-line arguments contain an opaque account identifier.
// ==============================================================================

import Darwin
import Foundation
import Security

let kKeychainTokenWriteFlag = "--keychain-token-write"
let kKeychainTokenReadFlag = "--keychain-token-read"
let kKeychainTokenDeleteFlag = "--keychain-token-delete"
let kKeychainTokenService = "org.ergopti.llm-api-token"

private let kMaximumKeychainTokenBytes = 65_536
private let kMaximumKeychainAccountBytes = 1_024

enum KeychainTokenWorkerExit: Int32 {
	case success = 0
	case invalidArguments = 64
	case inputFailure = 65
	case keychainFailure = 70
	case outputFailure = 74
}

enum KeychainTokenInvocation: Equatable {
	case write(account: String)
	case read(account: String)
	case delete(account: String)

	static func parse(arguments: [String]) -> KeychainTokenInvocation? {
		guard arguments.count == 3 else { return nil }
		let account = arguments[2]
		guard !account.isEmpty,
			account.utf8.count <= kMaximumKeychainAccountBytes,
			!account.utf8.contains(0)
		else { return nil }
		switch arguments[1] {
		case kKeychainTokenWriteFlag:
			return .write(account: account)
		case kKeychainTokenReadFlag:
			return .read(account: account)
		case kKeychainTokenDeleteFlag:
			return .delete(account: account)
		default:
			return nil
		}
	}
}

protocol KeychainTokenStoring {
	func write(account: String, secret: Data) -> OSStatus
	func read(account: String) -> (OSStatus, Data?)
	func delete(account: String) -> OSStatus
}

struct SystemKeychainTokenStore: KeychainTokenStoring {
	private func query(account: String) -> [CFString: Any] {
		return [
			kSecClass: kSecClassGenericPassword,
			kSecAttrService: kKeychainTokenService,
			kSecAttrAccount: account,
		]
	}

	func write(account: String, secret: Data) -> OSStatus {
		let match = query(account: account)
		let update: [CFString: Any] = [kSecValueData: secret]
		let updateStatus = SecItemUpdate(match as CFDictionary, update as CFDictionary)
		if updateStatus != errSecItemNotFound { return updateStatus }

		var add = match
		add[kSecValueData] = secret
		let addStatus = SecItemAdd(add as CFDictionary, nil)
		if addStatus == errSecDuplicateItem {
			// Another exact helper may have won the add race after our lookup.
			return SecItemUpdate(match as CFDictionary, update as CFDictionary)
		}
		return addStatus
	}

	func read(account: String) -> (OSStatus, Data?) {
		var match = query(account: account)
		match[kSecReturnData] = true
		match[kSecMatchLimit] = kSecMatchLimitOne
		var result: CFTypeRef?
		let status = SecItemCopyMatching(match as CFDictionary, &result)
		guard status == errSecSuccess else { return (status, nil) }
		guard let secret = result as? Data else { return (errSecDecode, nil) }
		return (errSecSuccess, secret)
	}

	func delete(account: String) -> OSStatus {
		return SecItemDelete(query(account: account) as CFDictionary)
	}
}

enum KeychainTokenWorker {
	static func handles(arguments: [String]) -> Bool {
		guard arguments.count > 1 else { return false }
		return arguments[1] == kKeychainTokenWriteFlag
			|| arguments[1] == kKeychainTokenReadFlag
			|| arguments[1] == kKeychainTokenDeleteFlag
	}

	static func run(arguments: [String]) -> Int32 {
		guard let invocation = KeychainTokenInvocation.parse(arguments: arguments) else {
			return KeychainTokenWorkerExit.invalidArguments.rawValue
		}
		let input: Data?
		switch invocation {
		case .write:
			input = readBoundedInput()
			if input == nil { return KeychainTokenWorkerExit.inputFailure.rawValue }
		default:
			input = nil
		}
		return execute(
			invocation: invocation,
			input: input,
			store: SystemKeychainTokenStore(),
			writeOutput: writeStandardOutput
		)
	}

	/// Testable operation boundary. The input is supplied separately from argv so
	/// a regression that places a secret in process arguments cannot hide here.
	static func run(
		arguments: [String],
		input: Data?,
		store: KeychainTokenStoring,
		writeOutput: (Data) -> Bool
	) -> Int32 {
		guard let invocation = KeychainTokenInvocation.parse(arguments: arguments) else {
			return KeychainTokenWorkerExit.invalidArguments.rawValue
		}
		return execute(
			invocation: invocation,
			input: input,
			store: store,
			writeOutput: writeOutput
		)
	}

	private static func execute(
		invocation: KeychainTokenInvocation,
		input: Data?,
		store: KeychainTokenStoring,
		writeOutput: (Data) -> Bool
	) -> Int32 {
		switch invocation {
		case .write(let account):
			guard let secret = input,
				!secret.isEmpty,
				secret.count <= kMaximumKeychainTokenBytes
			else { return KeychainTokenWorkerExit.inputFailure.rawValue }
			return store.write(account: account, secret: secret) == errSecSuccess
				? KeychainTokenWorkerExit.success.rawValue
				: KeychainTokenWorkerExit.keychainFailure.rawValue

		case .read(let account):
			let (status, secret) = store.read(account: account)
			guard status == errSecSuccess, let secret, !secret.isEmpty else {
				return KeychainTokenWorkerExit.keychainFailure.rawValue
			}
			return writeOutput(secret)
				? KeychainTokenWorkerExit.success.rawValue
				: KeychainTokenWorkerExit.outputFailure.rawValue

		case .delete(let account):
			let status = store.delete(account: account)
			return status == errSecSuccess || status == errSecItemNotFound
				? KeychainTokenWorkerExit.success.rawValue
				: KeychainTokenWorkerExit.keychainFailure.rawValue
		}
	}

	private static func readBoundedInput() -> Data? {
		var result = Data()
		var buffer = [UInt8](repeating: 0, count: 4_096)
		while true {
			let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
			if count == 0 { return result }
			if count < 0 {
				if errno == EINTR { continue }
				return nil
			}
			if result.count + count > kMaximumKeychainTokenBytes { return nil }
			result.append(contentsOf: buffer[0..<count])
		}
	}

	private static func writeStandardOutput(_ data: Data) -> Bool {
		return data.withUnsafeBytes { rawBuffer in
			guard let base = rawBuffer.baseAddress else { return data.isEmpty }
			var offset = 0
			while offset < rawBuffer.count {
				let written = Darwin.write(
					STDOUT_FILENO,
					base.advanced(by: offset),
					rawBuffer.count - offset
				)
				if written < 0 {
					if errno == EINTR { continue }
					return false
				}
				if written == 0 { return false }
				offset += written
			}
			return true
		}
	}
}
