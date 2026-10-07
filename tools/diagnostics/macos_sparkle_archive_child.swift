// tools/diagnostics/macos_sparkle_archive_child.swift
//
// Compiled only by the native archive XCTest into a disposable application.
// Its automatic replies belong exclusively to this private acceptance fixture.

import AppKit
import Darwin
import Sparkle

private enum PhysicalFixtureFailure: Error { case refused }

/// Foundation may project /private aliases; only Darwin supplies physical identity.
private func physicalFixtureDirectory(_ source: URL) throws -> URL {
	guard source.isFileURL, source.path.hasPrefix("/") else { throw PhysicalFixtureFailure.refused }
	let resolved = source.withUnsafeFileSystemRepresentation { value -> UnsafeMutablePointer<CChar>? in
		guard let value else { return nil }
		return Darwin.realpath(value, nil)
	}
	guard let resolved else { throw PhysicalFixtureFailure.refused }
	defer { free(resolved) }
	var metadata = stat()
	guard lstat(resolved, &metadata) == 0,
		metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
		let nativePath = String(validatingUTF8: resolved), nativePath.hasPrefix("/") else {
		throw PhysicalFixtureFailure.refused
	}
	let result = URL(fileURLWithPath: nativePath, isDirectory: true)
	guard result.path == nativePath else { throw PhysicalFixtureFailure.refused }
	return result
}

final class PrivateArchiveChild: NSObject, NSApplicationDelegate, SPUUserDriver, SPUUpdaterDelegate {
	private let root: URL
	private let nonce: String
	private let version: String
	private var updater: SPUUpdater?
	private var controls: Timer?
	private var phase = 1
	private var refusedCycleClosed = false

	init(root: URL, nonce: String, version: String) {
		self.root = root
		self.nonce = nonce
		self.version = version
	}

	/// Exclusive final links prevent another callback from replacing evidence.
	private func record(_ event: String, details: [String: Any] = [:]) {
		do {
			let packet: [String: Any] = [
				"nonce": nonce, "pid": ProcessInfo.processInfo.processIdentifier,
				"version": version, "event": event, "details": details
			]
			let data = try JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys])
			let stage = root.appendingPathComponent("." + UUID().uuidString + ".stage")
			let descriptor = open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
			guard descriptor >= 0 else { throw Failure.refused }
			let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
			try stream.write(contentsOf: data)
			try stream.synchronize()
			try stream.close()
			let target = root.appendingPathComponent(event + ".json")
			guard link(stage.path, target.path) == 0 else { throw Failure.refused }
			guard unlink(stage.path) == 0 else { throw Failure.refused }
		} catch {
			fputs("Private Sparkle receipt publication refused.\n", stderr)
			exit(78)
		}
	}

	private enum Failure: Error { case refused }

	/// Capture only typed error identities, not descriptions or signing inputs.
	private func identities(_ error: Error) -> [[String: Any]] {
		var result: [[String: Any]] = []
		var current: NSError? = error as NSError
		while let value = current, result.count < 8 {
			result.append(["domain": value.domain, "code": value.code])
			current = value.userInfo[NSUnderlyingErrorKey] as? NSError
		}
		return result
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		record("started-" + version, details: ["bundle": Bundle.main.bundleURL.path])
		controls = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
			self?.pollControls()
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
			self?.record("deadline-" + (self?.version ?? "unknown"))
			NSApplication.shared.terminate(nil)
		}
		guard version == "1" else { return }
		let owner = SPUUpdater(hostBundle: Bundle.main, applicationBundle: Bundle.main,
			userDriver: self, delegate: self)
		updater = owner
		do {
			try owner.start()
			record("updater-started-1")
			guard !owner.automaticallyChecksForUpdates, !owner.automaticallyDownloadsUpdates,
				!owner.allowsAutomaticUpdates else { throw Failure.refused }
			owner.checkForUpdates()
			record("check-requested-1")
		} catch {
			record("start-refused", details: ["errors": identities(error)])
			NSApplication.shared.terminate(nil)
		}
	}

	private func pollControls() {
		let stop = root.appendingPathComponent("retire")
		if FileManager.default.fileExists(atPath: stop.path) {
			guard (try? Data(contentsOf: stop)) == Data(nonce.utf8) else {
				record("control-refused-" + version)
				exit(78)
			}
			NSApplication.shared.terminate(nil)
			return
		}
		let retry = root.appendingPathComponent("retry")
		if phase == 1, refusedCycleClosed, FileManager.default.fileExists(atPath: retry.path) {
			guard (try? Data(contentsOf: retry)) == Data(nonce.utf8),
				let owner = updater, !owner.sessionInProgress else { return }
			phase = 2
			record("retry-accepted")
			owner.checkForUpdates()
		}
	}

	func applicationWillTerminate(_ notification: Notification) {
		controls?.invalidate()
		record("terminated-" + version)
	}

	func show(_ request: SPUUpdatePermissionRequest,
		reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void) {
		record("unexpected-permission-" + String(phase))
		reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
	}

	func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

	func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
		reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
		guard appcastItem.versionString == "2", !appcastItem.isInformationOnlyUpdate,
			state.userInitiated else {
			record("offer-refused-" + String(phase))
			reply(.dismiss)
			return
		}
		record("offered-" + String(phase), details: ["offered_version": appcastItem.versionString])
		reply(.install)
	}

	func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
	func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

	func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
		record("not-found-" + String(phase), details: ["errors": identities(error)])
		acknowledgement()
	}

	func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
		record("refused-" + String(phase), details: ["errors": identities(error)])
		acknowledgement()
	}

	/// Sparkle parses the untouched production appcast. Route only its exact
	/// admitted request inside this disposable signed app, before native download.
	func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
		guard let originText = Bundle.main.object(forInfoDictionaryKey: "FixtureArchiveOrigin") as? String,
			let owner = Bundle.main.object(forInfoDictionaryKey: "FixtureGitHubOwner") as? String,
			let repository = Bundle.main.object(forInfoDictionaryKey: "FixtureGitHubRepo") as? String,
			originText == "https://github.com/" + owner + "/" + repository + "/releases/download/v2.0.0/ErgoptiPlus.app.tar.xz",
			let origin = URL(string: originText), item.fileURL == origin, request.url == origin,
			request.httpMethod == "GET", item.versionString == "2",
			let transportText = Bundle.main.object(forInfoDictionaryKey: "FixtureArchiveTransport") as? String,
			let transport = URL(string: transportText), transport.scheme == "http", transport.host == "localhost",
			let port = transport.port, (1...65535).contains(port), transport.path == "/archive.tar.xz",
			transport.user == nil, transport.password == nil, transport.query == nil, transport.fragment == nil,
			Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String == "http://localhost:" + String(port) + "/feed.xml" else {
			record("transport-refused-" + String(phase))
			exit(78) // The native downloader has not started, so no foreign origin is acquired.
		}
		request.url = transport
		request.httpShouldHandleCookies = false
		record("routed-" + String(phase), details: ["origin": origin.absoluteString, "transport": transport.absoluteString])
	}

	func showDownloadInitiated(cancellation: @escaping () -> Void) {
		record("download-" + String(phase))
	}
	func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
	func showDownloadDidReceiveData(ofLength length: UInt64) {}
	func showDownloadDidStartExtractingUpdate() { record("extracting-" + String(phase)) }
	func showExtractionReceivedProgress(_ progress: Double) {}

	func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
		record("ready-" + String(phase))
		reply(.install)
	}

	func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
		retryTerminatingApplication: @escaping () -> Void) {}

	func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
		acknowledgement()
	}
	func showUpdateInFocus() {}
	func dismissUpdateInstallation() {}

	func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
		record("installing-" + String(phase))
	}

	func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
		record("relaunch-requested-" + String(phase))
		return true
	}

	func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
		error: Error?) {
		guard let error else { return }
		record("cycle-refused-" + String(phase), details: ["errors": identities(error)])
		if phase == 1 { refusedCycleClosed = true }
	}
}

// The updater never targets XCTest or a product app. Relaunch derives the same
// private root from the signed replacement's plist, without inherited arguments.
guard let rootPath = Bundle.main.object(forInfoDictionaryKey: "FixtureRoot") as? String,
	let nonce = Bundle.main.object(forInfoDictionaryKey: "FixtureNonce") as? String,
	nonce.count == 32, nonce.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
	let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
	["1", "2"].contains(version),
	Bundle.main.bundleIdentifier == "org.ergoptiplus.archive-acceptance." + nonce else {
	fputs("Private Sparkle child configuration refused.\n", stderr)
	exit(78)
}
let root: URL
let physicalBundle: URL
do {
	root = try physicalFixtureDirectory(URL(fileURLWithPath: rootPath, isDirectory: true))
	physicalBundle = try physicalFixtureDirectory(Bundle.main.bundleURL)
} catch {
	fputs("Private Sparkle child target refused.\n", stderr)
	exit(78)
}
guard root.path == rootPath,
	physicalBundle == root.appendingPathComponent("installed/ErgoptiPlus.app", isDirectory: true) else {
	fputs("Private Sparkle child target refused.\n", stderr)
	exit(78)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = PrivateArchiveChild(root: root, nonce: nonce, version: version)
application.delegate = delegate
application.run()
