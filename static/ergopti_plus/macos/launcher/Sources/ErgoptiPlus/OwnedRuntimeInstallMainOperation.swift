// Sources/ErgoptiPlus/OwnedRuntimeInstallMainOperation.swift
// The user's confirmed first install of the owned runtime: the verified download's helper, staged behind the admin prompt.
import CryptoKit
import Darwin
import Foundation
import Security

/// Started only by the Lua install port after the user confirmed it (Tap-Holds row), never at startup. The helper
/// comes from the verified download only (OwnedRuntimeDownloadedHelper), must carry this launcher's own
/// certificate leaf and its code hashes, and the administrator shell copies it root-owned and proves that
/// requirement and its digest again before its one `--owned-install-first` transaction runs.
///
/// One stdout line answers, for platform/remap/runtime_install.lua:
/// - `OWNED_RUNTIME_INSTALL|1|<result>` relays the helper's own closed line (exit 0);
/// - `OWNED_RUNTIME_INSTALL_REQUEST|1|refused|<reason>` before any prompt (exit 77);
/// - `OWNED_RUNTIME_INSTALL_REQUEST|1|cancelled` when the prompt was closed (exit 1);
/// - `OWNED_RUNTIME_INSTALL_REQUEST|1|failed|<status>[|<step>]` when the administrator shell failed (exit 75),
///   with the staged program's failing step when it named one.
enum OwnedRuntimeInstallMainOperation {
	static let flag = "--request-owned-runtime-install"
	/// The helper's two closed result values (OwnedRuntimeIdleServiceEntry.Result).
	static let helperResults: Set<String> = ["files-published-services-observed-staging-retired", "files-published-service-cleanup-pending"]
	private static let installerExecutable = "Contents/MacOS/ErgoptiPlus-Runtime-Installer"
	/// AppleScript's error number for a prompt the user closed.
	private static let userCancelled = -128

	static func handles(arguments: [String]) -> Bool { arguments.count == 2 && arguments[1] == flag }

	/// The helper's code directory hashes: one per hash type, distinct, SHA-1 (20 bytes) or SHA-256 (32 bytes, as
	/// signing information reports it). codesign writes only the SHA-256 directory for a macOS 11+ target, so the
	/// published runtime carries one hash per slice; demanding two refused every install (field report 2026-11-05).
	/// - Parameter fields: Signing information of the helper.
	/// - Returns: The hashes, or nil when absent, duplicated, over two or of another length.
	static func codeDirectoryHashes(_ fields: [String: Any]) -> [Data]? {
		guard let hashes = fields[kSecCodeInfoCdHashes as String] as? [Data], (1...2).contains(hashes.count),
			Set(hashes).count == hashes.count, hashes.allSatisfy({ $0.count == 20 || $0.count == 32 }) else { return nil }
		return hashes
	}

	/// The `cdhash` of each architecture slice the helper carries, for the staged copy's requirement. The
	/// requirement language compares the 20-byte truncated hash, and `codesign --all-architectures` checks every
	/// slice: the full SHA-256 of the host slice alone matched neither, so the administrator shell refused every
	/// install with status 1 (field report 2026-11-05).
	/// - Parameter helper: The helper bundle.
	/// - Returns: One 20-byte hash per slice present, or nil when a present slice reports none or two collide.
	static func sliceCodeHashes(_ helper: URL) -> [Data]? {
		var hashes: [Data] = []
		for architecture in ["arm64", "x86_64"] {
			var code: SecStaticCode?
			let attributes = [kSecCodeAttributeArchitecture as String: architecture] as CFDictionary
			// An architecture the universal file does not carry has no slice to admit.
			guard SecStaticCodeCreateWithPathAndAttributes(helper as CFURL, [], attributes, &code) == errSecSuccess,
				let code else { continue }
			var information: CFDictionary?
			guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
				let unique = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data, unique.count == 20 else { return nil }
			hashes.append(unique)
		}
		return hashes.isEmpty || Set(hashes).count != hashes.count ? nil : hashes
	}

	/// The staged helper's requirement: Ergopti's installer identifier, this launcher's leaf and one slice's cdhash.
	/// - Parameters:
	///   - leaf: The launcher's certificate leaf.
	///   - slices: The helper's slice hashes (sliceCodeHashes).
	/// - Returns: The requirement text `codesign --test-requirement` reads.
	static func stagedRequirement(leaf: Data, slices: [Data]) -> String {
		let codeHashes = slices.map { "cdhash H\"" + hex($0) + "\"" }.sorted().joined(separator: " or ")
		return "identifier \"" + Identifiers.SigningIds.runtimeInstaller + "\" and certificate leaf = H\""
			+ hex(Insecure.SHA1.hash(data: leaf)) + "\" and (" + codeHashes + ")"
	}

	/// The step the staged program names on stderr (OwnedVirtualHIDDaemonReportMainOperation.failedStepMarker),
	/// which `do shell script` returns as the error message of a failed shell.
	/// - Parameter message: The AppleScript error message.
	/// - Returns: The step, lower-case letters and underscores only, or nil when none is named.
	static func failedStep(_ message: String) -> String? {
		guard let range = message.range(of: OwnedVirtualHIDDaemonReportMainOperation.failedStepMarker, options: .backwards) else { return nil }
		let step = message[range.upperBound...].prefix { $0 == "_" || ("a"..."z").contains($0) }
		return step.isEmpty || step.count > 32 ? nil : String(step)
	}
	/// The shell's stderr on one bounded log line: codesign and ditto say there why they refused.
	static func oneLine(_ message: String) -> String {
		let flat = message.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
			.filter { !$0.isEmpty }.joined(separator: " | ")
		return flat.count > 600 ? String(flat.prefix(600)) + "…" : flat
	}

	/// Writes the one answer line, then returns the exit status.
	private static func answer(_ line: String, _ status: Int32) -> Int32 {
		do { try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8)) } catch { return 75 }
		return status
	}
	private static func refuse(_ reason: String, _ explanation: String) -> Int32 {
		LauncherLog.write("owned runtime install: refused (\(reason)): \(explanation).")
		return answer("OWNED_RUNTIME_INSTALL_REQUEST|1|refused|" + reason, 77)
	}
	private static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

	/// Exit statuses of the driver step's own checks (runtime_vhid_update.lua EXIT_DIGEST and EXIT_SIGNATURE).
	static let driverDigestStatus = 78, driverSignatureStatus = 79

	/// Root-owned copy of the kept package, its pinned digest and pqrs' Developer ID Installer team checked on that
	/// copy, then /usr/sbin/installer; the same checks as the driver-only update's administrator shell.
	static func driverProgram(_ package: OwnedRuntimeDownloadedHelper.DriverPackage) -> String {
		let quote = OwnedVirtualHIDDaemonReportMainOperation.quote
		return "task_step=driver_package; task_work=$(/usr/bin/mktemp -d /private/tmp/ergoptiplus-vhid.XXXXXX); "
			+ "/bin/cp -X " + quote(package.path) + " \"$task_work/driver.pkg\"; "
			+ "task_sum=$(/usr/bin/shasum -a 256 \"$task_work/driver.pkg\"); task_sum=${task_sum%% *}; "
			+ "[ \"$task_sum\" = " + quote(package.sha256) + " ] || { /bin/rm -rf \"$task_work\"; exit \(driverDigestStatus); }; "
			+ "task_sig=$(/usr/sbin/pkgutil --check-signature \"$task_work/driver.pkg\") || { /bin/rm -rf \"$task_work\"; exit \(driverSignatureStatus); }; "
			+ "printf '%s\\n' \"$task_sig\" | /usr/bin/grep -q '^ *Status: signed by a developer certificate issued by Apple' "
			+ "|| { /bin/rm -rf \"$task_work\"; exit \(driverSignatureStatus); }; "
			+ "printf '%s\\n' \"$task_sig\" | /usr/bin/grep -Eq '^ *1\\. Developer ID Installer: .*\\(" + package.team + "\\)$' "
			+ "|| { /bin/rm -rf \"$task_work\"; exit \(driverSignatureStatus); }; "
			+ "/usr/sbin/installer -pkg \"$task_work/driver.pkg\" -target / >/dev/null; /bin/rm -rf \"$task_work\"; "
	}

	/// Deliberate signed Main CLI request, off the main thread (the AppleScript prompt runs here).
	static func run(arguments: [String]) -> Int32 {
		guard handles(arguments: arguments), !Thread.isMainThread, getuid() != 0, getuid() == geteuid() else { return 64 }
		guard let publisher = OwnedRuntimePublisherIdentity.currentLauncher(), publisher.current() else {
			return refuse("launcher_unsigned", "this launcher carries no stable Ergopti signature to vouch for the installer helper")
		}
		defer { _ = publisher.retire() }
		let helper: URL
		switch OwnedRuntimeDownloadedHelper.current() {
		case .success(let located): helper = located
		case .failure(let refusal): return refuse(refusal.rawValue, refusal.explanation)
		}
		// pqrs' driver package, when no pqrs daemon is installed yet: the Lua install port downloaded and
		// verified it (runtime_vhid_update.lua fetch), and this same shell checks it again before the helper.
		var driverStep = ""
		if !OwnedRuntimeVirtualHIDProvisionOwner.daemonInstalled() {
			guard let package = OwnedRuntimeDownloadedHelper.currentDriverPackage() else {
				return refuse("driver_package_absent", "no verified VirtualHIDDevice package is kept for the driver install")
			}
			driverStep = Self.driverProgram(package)
		}
		let program: String
		do {
			let source = try OwnedRuntimeInstallTree(root: helper, protected: false)
			defer { _ = source.releaseOwnedDescriptors() }
			// One refusal per cause: a single "helper_signature" for all three left an
			// install refused on a signed release with nothing to tell them apart
			// (field report 2026-11-05, issue #106).
			var code: SecStaticCode?
			guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
				let fields = OwnedRuntimePublisherSignature.information(code, role: .installer),
				let certificates = fields[kSecCodeInfoCertificates as String] as? [SecCertificate],
				let certificate = certificates.first else {
				return refuse("helper_signature_invalid",
					"the downloaded installer helper fails its strict signature check or is not Ergopti's installer")
			}
			guard SecCertificateCopyData(certificate) as Data == publisher.leaf else {
				return refuse("helper_signature", "the downloaded installer helper is not signed with this launcher's certificate")
			}
			guard codeDirectoryHashes(fields) != nil, let slices = sliceCodeHashes(helper) else {
				return refuse("helper_code_hashes", "the downloaded installer helper's code hashes could not be read")
			}
			let bytes = try Data(contentsOf: helper.appendingPathComponent(installerExecutable))
			guard OwnedRuntimeInstallOwner.systemClosedExecutableForInstaller(bytes) else {
				return refuse("helper_executable", "the downloaded installer helper links outside the system libraries")
			}
			try source.verify()
			let stage = URL(fileURLWithPath: "/Library/Application Support/ErgoptiPlus/.runtime-installer-" + UUID().uuidString + "/Helper.app")
			let requirement = stagedRequirement(leaf: publisher.leaf, slices: slices)
			let directory = OwnedVirtualHIDDaemonReportMainOperation.quote(stage.deletingLastPathComponent().path)
			program = OwnedVirtualHIDDaemonReportMainOperation.stagedHelperProgram(source: helper.path, stage: stage,
				requirement: requirement, digest: hex(SHA256.hash(data: bytes))) { executable in
				// The helper retires its own stage on success; any other exit leaves a copy only this shell can remove.
				driverStep + "task_step=helper; task_status=0; task_line=$(/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin "
					+ OwnedVirtualHIDDaemonReportMainOperation.quote(executable) + " --owned-install-first) || task_status=$?; "
					+ "if [ -d \(directory) ] && [ ! -L \(directory) ]; then /bin/rm -rf \(directory); fi; "
					+ "printf '%s\\n' \"$task_line\"; exit \"$task_status\""
			}
		} catch {
			return refuse("helper_unreadable", "the downloaded installer helper could not be read and verified")
		}
		guard publisher.current(), let script = NSAppleScript(source: "do shell script "
			+ OwnedVirtualHIDDaemonReportMainOperation.appleQuote("/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/sh -c "
				+ OwnedVirtualHIDDaemonReportMainOperation.quote(program)) + " with administrator privileges") else {
			return refuse("launcher_changed", "this launcher's signature changed before the administrator prompt")
		}
		LauncherLog.write("owned runtime install: asking for the administrator prompt.")
		var error: NSDictionary?
		let output = script.executeAndReturnError(&error)
		if let error {
			let number = error[NSAppleScript.errorNumber] as? Int ?? 0
			if number == userCancelled {
				LauncherLog.write("owned runtime install: the administrator prompt was cancelled.")
				return answer("OWNED_RUNTIME_INSTALL_REQUEST|1|cancelled", 1)
			}
			let message = error[NSAppleScript.errorMessage] as? String ?? ""
			let step = failedStep(message)
			LauncherLog.write("owned runtime install: the administrator shell failed with status \(number) at step "
				+ (step ?? "unnamed") + ": " + oneLine(message) + ".")
			return answer("OWNED_RUNTIME_INSTALL_REQUEST|1|failed|" + String(number) + (step.map { "|" + $0 } ?? ""), 75)
		}
		let line = (output.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
		let prefix = "OWNED_RUNTIME_INSTALL|1|"
		guard line.hasPrefix(prefix), helperResults.contains(String(line.dropFirst(prefix.count))) else {
			LauncherLog.write("owned runtime install: the helper answered no closed result line.")
			return answer("OWNED_RUNTIME_INSTALL_REQUEST|1|failed|unanswered", 75)
		}
		LauncherLog.write("owned runtime install: the helper answered \(line).")
		return answer(line, 0)
	}
}
