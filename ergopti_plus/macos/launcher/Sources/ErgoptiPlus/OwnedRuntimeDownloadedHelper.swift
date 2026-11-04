// Sources/ErgoptiPlus/OwnedRuntimeDownloadedHelper.swift
// Locates the privileged installer helper of the verified owned-runtime download (ADR 011, WP5).
import Darwin
import Foundation

/// The signed `ErgoptiPlus-Runtime-Installer.app` the administrator install stages.
///
/// `platform/remap/runtime_artifact_fetch.lua` downloads the pinned artifact, checks its size,
/// digest and closed member list, extracts it to
/// `~/Library/Application Support/ErgoptiPlus/RemapRuntime/<version>/payload/` and writes the
/// `receipt`, which names the pinned SHA-256, last. The helper comes from that payload only, and
/// only while the receipt names the digest the manifest pins: an absent download or a receipt of
/// another artifact is a named refusal, never the copy inside the application bundle. The checks
/// that follow (publisher leaf, the two cdhashes, the descriptor-checked tree, the administrator
/// copy) stay with `OwnedVirtualHIDDaemonReportMainOperation`.
enum OwnedRuntimeDownloadedHelper {
	/// Stable reasons of a refused helper source, beside the Lua fetch's `artifact_*` reasons.
	enum Refusal: String, Error, Equatable {
		case manifestUnreadable = "artifact_manifest_unreadable"
		case unpinned = "artifact_unpinned"
		case accountUnavailable = "artifact_account_unavailable"
		case downloadAbsent = "artifact_download_absent"
		case receiptMismatch = "artifact_receipt_mismatch"
		case helperAbsent = "artifact_helper_absent"

		/// One sentence for launcher.log.
		var explanation: String {
			switch self {
			case .manifestUnreadable: return "the runtime manifest could not be read"
			case .unpinned: return "the runtime artifact is not pinned in the manifest"
			case .accountUnavailable: return "the current account's home folder could not be resolved"
			case .downloadAbsent: return "the pinned runtime artifact has not been downloaded and verified yet"
			case .receiptMismatch: return "the kept artifact's receipt does not name the pinned digest"
			case .helperAbsent: return "the verified artifact holds no installer helper"
			}
		}
	}

	/// The part of the manifest's `runtime` pin that names the kept download.
	struct Pin: Equatable {
		let version: String
		let sha256: String
	}

	/// The artifact's one top-level member (runtime_artifact_fetch.lua `HELPER`).
	static let helperName = "ErgoptiPlus-Runtime-Installer.app"
	/// `ke_paths.lua` `OWNED.ARTIFACT_HOME`, relative to the account's home folder.
	static let artifactHomeRelative = "Library/Application Support/ErgoptiPlus/RemapRuntime"
	/// The manifest the Lua fetch reads, relative to the driver folder.
	static let manifestRelative = "vendor/remap-runtime/manifest.json"
	/// The receipt holds one digest line; anything larger is not a receipt.
	private static let receiptLimit = 256
	/// The pin keys runtime_artifact_fetch.lua requires before any fetch.
	private static let pinKeys = ["version", "file_name", "source_url", "sha256", "size"]

	/// Reads the runtime pin of manifest bytes.
	/// - Parameter manifest: The bytes of `manifest.json`.
	/// - Returns: The pin, or `.unpinned` while any pin field is still null or malformed.
	static func pin(manifest: Data) -> Result<Pin, Refusal> {
		guard let root = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any],
			let runtime = root["runtime"] as? [String: Any] else { return .failure(.manifestUnreadable) }
		guard pinKeys.allSatisfy({ runtime[$0] != nil && !(runtime[$0] is NSNull) }),
			let version = runtime["version"] as? String, validVersion(version),
			let sha256 = runtime["sha256"] as? String, validDigest(sha256) else { return .failure(.unpinned) }
		return .success(Pin(version: version, sha256: sha256))
	}

	/// The helper of a kept download, for one pin and one home folder.
	/// - Parameters:
	///   - pin: The manifest's runtime pin.
	///   - home: Absolute home folder of the current account.
	/// - Returns: The helper bundle URL, or the named refusal.
	static func locate(pin: Pin, home: String) -> Result<URL, Refusal> {
		guard home.hasPrefix("/"), !home.contains("\0"), !home.contains("\n") else { return .failure(.accountUnavailable) }
		guard validVersion(pin.version), validDigest(pin.sha256) else { return .failure(.unpinned) }
		let folder = URL(fileURLWithPath: home, isDirectory: true)
			.appendingPathComponent(artifactHomeRelative, isDirectory: true)
			.appendingPathComponent(pin.version, isDirectory: true)
		let receipt: Data
		switch readReceipt(folder.appendingPathComponent("receipt").path) {
		case .success(let bytes): receipt = bytes
		case .failure(let refusal): return .failure(refusal)
		}
		// The Lua fetch writes exactly the digest and one newline, after the payload is complete.
		guard receipt == Data((pin.sha256 + "\n").utf8) else { return .failure(.receiptMismatch) }
		let payload = folder.appendingPathComponent("payload", isDirectory: true)
		let helper = payload.appendingPathComponent(helperName, isDirectory: true)
		guard isDirectory(payload.path), isDirectory(helper.path) else { return .failure(.helperAbsent) }
		return .success(helper)
	}

	/// The helper of a kept download, reading the manifest of one driver folder.
	/// - Parameters:
	///   - configDir: The driver folder whose Lua fetched the artifact.
	///   - home: Absolute home folder of the current account.
	/// - Returns: The helper bundle URL, or the named refusal.
	static func locate(configDir: String, home: String) -> Result<URL, Refusal> {
		let manifest = URL(fileURLWithPath: configDir, isDirectory: true).appendingPathComponent(manifestRelative)
		guard let bytes = try? Data(contentsOf: manifest) else { return .failure(.manifestUnreadable) }
		switch pin(manifest: bytes) {
		case .success(let value): return locate(pin: value, home: home)
		case .failure(let refusal): return .failure(refusal)
		}
	}

	/// The helper of this launcher's verified download: the manifest of the Lua source this
	/// bundle runs (the packaged tree or the recorded developer clone) and the account's home
	/// folder from the user database, never from the caller's environment.
	/// - Returns: The helper bundle URL, or the named refusal.
	static func current() -> Result<URL, Refusal> {
		let selection = LuaSourceSelection.resolve(
			infoDictionary: Bundle.main.infoDictionary,
			bundlePath: Bundle.main.bundlePath,
			fileExists: { FileManager.default.fileExists(atPath: $0) }
		)
		guard let configDir = selection.configDir else { return .failure(.manifestUnreadable) }
		guard let home = accountHome() else { return .failure(.accountUnavailable) }
		return locate(configDir: configDir, home: home)
	}

	/// The same version shape runtime_artifact_fetch.lua admits, minus the dot-only names that
	/// would leave the RemapRuntime folder.
	private static func validVersion(_ version: String) -> Bool {
		guard !version.isEmpty, version != ".", version != "..", !version.contains("..") else { return false }
		return version.unicodeScalars.allSatisfy { scalar in
			scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || ".-+".unicodeScalars.contains(scalar))
		}
	}

	/// A lowercase SHA-256, as the packager writes it.
	private static func validDigest(_ digest: String) -> Bool {
		digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
	}

	/// Reads the receipt without following a link and without trusting a non-regular file.
	private static func readReceipt(_ path: String) -> Result<Data, Refusal> {
		let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
		guard descriptor >= 0 else { return .failure(errno == ENOENT ? .downloadAbsent : .receiptMismatch) }
		defer { close(descriptor) }
		var info = stat()
		guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
			info.st_size >= 0, info.st_size <= off_t(receiptLimit) else { return .failure(.receiptMismatch) }
		let capacity = receiptLimit + 1
		var bytes = [UInt8](repeating: 0, count: capacity)
		let count = read(descriptor, &bytes, capacity)
		guard count >= 0, count <= receiptLimit else { return .failure(.receiptMismatch) }
		return .success(Data(bytes.prefix(count)))
	}

	/// Whether a path is a real directory, not a link to one.
	private static func isDirectory(_ path: String) -> Bool {
		var info = stat()
		return lstat(path, &info) == 0 && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
	}

	/// The current account's home folder from the user database.
	private static func accountHome() -> String? {
		let size = sysconf(_SC_GETPW_R_SIZE_MAX)
		guard size > 0, size <= 1_048_576 else { return nil }
		var storage = [CChar](repeating: 0, count: Int(size))
		return storage.withUnsafeMutableBufferPointer { bytes in
			var account = passwd(), result: UnsafeMutablePointer<passwd>?
			guard getpwuid_r(getuid(), &account, bytes.baseAddress, bytes.count, &result) == 0, result != nil,
				account.pw_uid == getuid(), let home = account.pw_dir else { return nil }
			return String(cString: home)
		}
	}
}
