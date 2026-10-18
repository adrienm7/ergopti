// Sources/ErgoptiPlus/OwnedVirtualHIDDaemonReportWorker.swift
import Darwin
import Dispatch
import Foundation

/// Headless report from an already administrator-staged helper; this never elevates or installs code.
enum OwnedVirtualHIDDaemonReportWorker {
	static func handles(arguments: [String]) -> Bool {
		arguments.count == 2 && arguments[1] == "--virtual-hid-daemon-report-worker"
	}

	/// The observer enforces the actual executing publisher and native identity independently of routing.
	static func run(arguments: [String]) -> Int32 {
		guard handles(arguments: arguments) else { return 64 }
		guard getuid() == 0, geteuid() == 0 else { return 77 }
		let completion = Completion(), finished = DispatchSemaphore(value: 0)
		DispatchQueue(label: "com.ergoptiplus.virtual-hid-daemon-report").async {
			defer { finished.signal() }
			completion.finish(receiveReport(completion))
		}
		if finished.wait(timeout: .now() + 120) == .timedOut {
			completion.stop()
			return 75 // Original cleanup is unknown; process exit is not a staging-retirement ACK.
		}
		return completion.result() ?? 75
	}

	private static func receiveReport(_ completion: Completion) -> Int32 {
		let root = OwnedVirtualHIDDaemonReportRequestChannel.Root.acquire()
		guard let began = OwnedVirtualHIDDaemonReportClock.now() else { _ = root.retire(); return 75 }
		var accepted: OwnedVirtualHIDDaemonReportRequestChannel.Root.Request?
		while root.current(), OwnedVirtualHIDDaemonReportClock.remains(began), !completion.withdrawn() {
			if let request = root.receiveRequest() { accepted = request; break }
			usleep(20_000)
		}
		guard let request = accepted else { return root.retire() == nil ? 75 : 77 }
		let stage = OwnedVirtualHIDDaemonReportStageOwner.capture(from: request)
		guard stage.captured() else {
			_ = root.send(observation: .cleanupPending(.cleanup))
			_ = root.retire()
			return 75 // A partial original stage is retained; no foreign or recursive cleanup.
		}
		let observation: OwnedVirtualHIDDaemonReportObserver.Observation
		if request.withdrawn() || completion.withdrawn() {
			observation = .unavailable(.stopped)
		} else if !request.current() {
			observation = .unavailable(.authority)
		} else {
			let observer = OwnedVirtualHIDDaemonReportObserver.acquire()
			completion.retain(observer)
			let pump = WithdrawalPump(root: root, request: request, observer: observer)
			pump.start()
			let reported = observer.observe()
			guard pump.stopAndJoin() else { observer.stop(); return 75 }
			if request.withdrawn() || completion.withdrawn() {
				observation = observer.retired() ? .unavailable(.stopped) : .cleanupPending(.stopped)
			} else if !request.current() {
				observation = observer.retired() ? .unavailable(.authority) : .cleanupPending(.authority)
			} else { observation = reported }
		}
		let sent = root.send(observation: observation)
		guard let retirement = root.retire(), stage.retire(after: retirement), stage.retired() else { return 75 }
		guard sent else { return 75 }
		switch observation {
		case .historical: return 0
		case .unavailable: return 77
		case .cleanupPending: return 75
		}
	}

	/// Only fixed technical fields cross stdout; no native paths, identifiers or arbitrary messages.
	static func encoded(_ observation: OwnedVirtualHIDDaemonReportObserver.Observation) -> Data {
		let text: String
		switch observation {
		case .historical(let report):
			let value = report.values
			text = "{\"state\":\"historical\",\"remoteCleanup\":\"unobserved\","
				+ "\"driverActivated\":\(value.driverActivated),\"driverConnected\":\(value.driverConnected),"
				+ "\"driverVersionMismatched\":\(value.driverVersionMismatched),"
				+ "\"virtualHIDKeyboardReady\":\(value.virtualHIDKeyboardReady),"
				+ "\"virtualHIDPointingReady\":\(value.virtualHIDPointingReady)}"
		case .unavailable(let failure):
			text = "{\"state\":\"unavailable\",\"category\":\"\(category(failure))\",\"remoteCleanup\":\"unobserved\"}"
		case .cleanupPending(let failure):
			text = "{\"state\":\"cleanupPending\",\"category\":\"\(category(failure))\",\"remoteCleanup\":\"unobserved\"}"
		}
		return Data((text + "\n").utf8)
	}

	private static func category(_ failure: OwnedVirtualHIDDaemonReportObserver.Failure) -> String {
		switch failure {
		case .authority: return "authority"
		case .endpoint: return "endpoint"
		case .identity: return "identity"
		case .signature: return "signature"
		case .transport: return "transport"
		case .protocolFrame: return "protocolFrame"
		case .deadline: return "deadline"
		case .stopped: return "stopped"
		case .cleanup: return "cleanup"
		}
	}

	private final class Completion {
		private let lock = NSLock()
		private var observer: OwnedVirtualHIDDaemonReportObserver?
		private var stopped = false
		private var status: Int32?
		func retain(_ value: OwnedVirtualHIDDaemonReportObserver) {
			lock.lock(); observer = value; let withdrawn = stopped; lock.unlock()
			if withdrawn { value.stop() }
		}
		func stop() {
			lock.lock(); stopped = true; let original = observer; lock.unlock()
			original?.stop()
		}
		func withdrawn() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
		func finish(_ value: Int32) {
			lock.lock(); status = value; lock.unlock()
		}
		func result() -> Int32? {
			lock.lock(); defer { lock.unlock() }; return status
		}
	}

	/// Owns the actual negative callback frame; the original channel cannot retire while this frame runs.
	private final class WithdrawalPump {
		private let lock = NSLock(), finished = DispatchSemaphore(value: 0)
		private let root: OwnedVirtualHIDDaemonReportRequestChannel.Root
		private let request: OwnedVirtualHIDDaemonReportRequestChannel.Root.Request
		private let observer: OwnedVirtualHIDDaemonReportObserver
		private var stopping = false
		init(root: OwnedVirtualHIDDaemonReportRequestChannel.Root,
			request: OwnedVirtualHIDDaemonReportRequestChannel.Root.Request,
			observer: OwnedVirtualHIDDaemonReportObserver) {
			self.root = root; self.request = request; self.observer = observer
		}
		func start() {
			DispatchQueue(label: "com.ergoptiplus.virtual-hid-daemon-report-withdrawal").async {
				defer { self.finished.signal() }
				while !self.isStopping() {
					_ = self.root.receiveRequest()
					guard !self.request.withdrawn(), self.request.current() else { self.observer.stop(); return }
					usleep(20_000)
				}
			}
		}
		private func isStopping() -> Bool { lock.lock(); defer { lock.unlock() }; return stopping }
		func stopAndJoin() -> Bool {
			lock.lock(); stopping = true; lock.unlock()
			return finished.wait(timeout: .now() + 3) == .success
		}
	}
}
