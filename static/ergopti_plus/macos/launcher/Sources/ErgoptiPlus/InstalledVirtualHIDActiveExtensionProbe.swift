// Read-only native observations. No installation, approval or live-source authority.
import Foundation
import SystemExtensions

struct InstalledVHDActiveExtensionProperty: Encodable {
	let identifier: String
	let version: String
	let shortVersion: String
	let url: String
	let enabled: Bool
	let awaitingApproval: Bool
	let uninstalling: Bool

	enum CodingKeys: String, CodingKey {
		case identifier, version, url, enabled, uninstalling
		case shortVersion = "short_version", awaitingApproval = "awaiting_approval"
	}
}

struct InstalledVHDActiveExtensionObservation: Encodable {
	let schema = 1
	let queryIdentifier = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"
	let referenceQualified = false
	let approvalQualified = false
	let installedPositiveQualified = false
	let status: String
	let reason: String
	let properties: [InstalledVHDActiveExtensionProperty]
	let callbackCount: Int
	let elapsedMS: Int
	let errorDomain: String?
	let errorCode: Int?

	enum CodingKeys: String, CodingKey {
		case schema, status, reason, properties
		case queryIdentifier = "query_identifier", referenceQualified = "reference_qualified"
		case approvalQualified = "approval_qualified", installedPositiveQualified = "installed_positive_qualified"
		case callbackCount = "callback_count", elapsedMS = "elapsed_ms"
		case errorDomain = "error_domain", errorCode = "error_code"
	}
}

/// The actual OS request and delegate remain retained through observation.
/// Closing this observation does not cancel an OS request or acknowledge native
/// callback retirement; the standalone diagnostic process owns that settlement.
final class InstalledVirtualHIDActiveExtensionProbe: NSObject, OSSystemExtensionRequestDelegate {
	private static let identifier = "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice"
	private let lock = NSRecursiveLock()
	private let started = ProcessInfo.processInfo.systemUptime
	private var nativeRequest: OSSystemExtensionRequest?
	private var open = true
	private var closed = false
	private var callbacks = 0
	private var pending: InstalledVHDActiveExtensionObservation?
	private var final: InstalledVHDActiveExtensionObservation?

	private override init() {
		super.init()
		if #available(macOS 12.0, *) {
			nativeRequest = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
			nativeRequest?.delegate = self
		}
	}

	/// Fixed identifier only. The result is a historical observation, never a
	/// native source capability, continuously current approval or readiness.
	static func observe() -> InstalledVHDActiveExtensionObservation {
		let owner = InstalledVirtualHIDActiveExtensionProbe()
		guard Thread.isMainThread else { return owner.close(status: "query_refused", reason: "main_thread_required") }
		guard let request = owner.nativeRequest else {
			return owner.close(status: "unsupported", reason: "native_properties_api_unavailable")
		}
		OSSystemExtensionManager.shared.submitRequest(request)
		let deadline = owner.started + 8
		while owner.isWaiting, ProcessInfo.processInfo.systemUptime < deadline {
			_ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
		}
		// Allow already queued native callbacks to refuse a duplicate terminal
		// before returning bytes. Later callbacks grant no authority and are fenced.
		if !owner.isWaiting {
			_ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
		}
		return owner.close(status: "query_timeout", reason: "native_query_timeout")
	}

	private var isWaiting: Bool {
		lock.lock(); defer { lock.unlock() }
		return open && pending == nil
	}

	private func packet(_ status: String, _ reason: String,
		properties: [InstalledVHDActiveExtensionProperty] = [], error: NSError? = nil) -> InstalledVHDActiveExtensionObservation {
		InstalledVHDActiveExtensionObservation(status: status, reason: reason, properties: properties,
			callbackCount: callbacks, elapsedMS: max(0, Int((ProcessInfo.processInfo.systemUptime - started) * 1000)),
			errorDomain: error?.domain, errorCode: error?.code)
	}

	private func begin(_ candidate: OSSystemExtensionRequest) -> Bool {
		guard open, !closed else { return false }
		guard let nativeRequest, candidate === nativeRequest else {
			pending = packet("query_refused", "foreign_request_callback"); open = false
			return false
		}
		callbacks += 1
		guard callbacks == 1, pending == nil else {
			pending = packet("query_refused", "duplicate_native_callback"); open = false
			return false
		}
		return true
	}

	private func close(status: String, reason: String) -> InstalledVHDActiveExtensionObservation {
		lock.lock(); defer { lock.unlock() }
		if let final { return final }
		let result = pending ?? packet(status, reason)
		open = false; closed = true; final = result
		return result
	}

	/// Revokes observation admission only; makes no OS cancellation promise.
	func stop() {
		lock.lock(); defer { lock.unlock() }
		guard open, !closed else { return }
		open = false; pending = packet("query_refused", "observation_stopped")
	}

	@available(macOS 12.0, *)
	func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
		lock.lock(); defer { lock.unlock() }
		guard begin(request) else { return }
		guard properties.count <= 1 else { pending = packet("query_refused", "ambiguous_native_properties"); return }
		var values: [InstalledVHDActiveExtensionProperty] = []
		for property in properties {
			let url = property.url
			let identifier = property.bundleIdentifier
			let version = property.bundleVersion
			let shortVersion = property.bundleShortVersion
			guard open, !closed, callbacks == 1, pending == nil else { return }
			guard identifier == Self.identifier, url.isFileURL, url.host == nil || url.host == "",
				url.path.hasPrefix("/"), url.path.utf8.count <= 4096,
				!url.path.contains("\0"), !url.path.split(separator: "/").contains(".."),
				!version.isEmpty, version.utf8.count <= 64, !shortVersion.isEmpty, shortVersion.utf8.count <= 64 else {
				pending = packet("query_refused", "native_property_fields_refused"); return
			}
			values.append(InstalledVHDActiveExtensionProperty(identifier: identifier, version: version,
				shortVersion: shortVersion, url: url.path, enabled: property.isEnabled,
				awaitingApproval: property.isAwaitingUserApproval, uninstalling: property.isUninstalling))
			guard open, !closed, callbacks == 1, pending == nil else { return }
		}
		pending = packet(values.isEmpty ? "observed_empty" : "observed_properties",
			values.isEmpty ? "native_properties_empty" : "native_properties_observed", properties: values)
	}

	func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
		lock.lock(); defer { lock.unlock() }
		guard begin(request) else { return }
		pending = packet("query_denied", "native_query_failed", error: error as NSError)
	}

	private func unexpected(_ request: OSSystemExtensionRequest) {
		lock.lock(); defer { lock.unlock() }
		guard begin(request) else { return }
		pending = packet("query_refused", "unexpected_native_callback")
	}

	func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) { unexpected(request) }
	func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) { unexpected(request) }
	func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
		withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
		unexpected(request); return .cancel
	}

	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	static func lifecycleForTest() -> InstalledVirtualHIDActiveExtensionProbe { InstalledVirtualHIDActiveExtensionProbe() }
	var requestForTest: OSSystemExtensionRequest? { nativeRequest }
	func finishForTest() -> InstalledVHDActiveExtensionObservation { close(status: "query_timeout", reason: "native_query_timeout") }
	#endif
}
