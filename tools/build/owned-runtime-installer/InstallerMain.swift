// Standalone distinct privileged helper entry; excluded from the ordinary launcher target.
import Darwin
import Foundation
@main
struct OwnedRuntimeInstallerMain {
	static func main() {
		umask(kPrivateProcessUmask)
		#if ERGOPTI_DAEMON_REPORT
		if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--query-vhd-daemon-report-purpose" {
			do { try FileHandle.standardOutput.write(contentsOf: Data("OWNED_VHD_DAEMON_REPORT_PURPOSE|1|readonly-historical\n".utf8)) }
			catch { Darwin.exit(75) }
			Darwin.exit(0)
		}
		if OwnedVirtualHIDDaemonReportWorker.handles(arguments: CommandLine.arguments) {
			Darwin.exit(OwnedVirtualHIDDaemonReportWorker.run(arguments: CommandLine.arguments))
		}
		#endif
		#if ERGOPTI_OWNED_IDLE_CORE
		// The service repair of an already published Runtime (MRT-004), which the first install refuses by design.
		if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == OwnedRuntimeServiceRepairEntry.argument {
			let repaired = OwnedRuntimeServiceRepairEntry.run()
			switch repaired {
			case .servicesObserved, .servicePending: report(repaired.rawValue, kind: "OWNED_RUNTIME_REPAIR")
			case .refused: Darwin.exit(77)
			case .cleanupPending: Darwin.exit(75)
			}
		}
		#endif
		guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--owned-install-first" else { Darwin.exit(64) }
		#if ERGOPTI_OWNED_IDLE_CORE
		// The live helper also starts the idle Core control service and loads the VirtualHIDDevice daemon job (ADR 011, WP8).
		let result = OwnedRuntimeIdleServiceEntry.runFirstInstallation()
		switch result {
		case .servicesObservedStagingRetired, .filesPublishedServiceCleanupPending: report(result.rawValue)
		case .refused: Darwin.exit(77)
		case .cleanupPending: Darwin.exit(75)
		}
		#else
		let result = OwnedRuntimeInstallerEntry.runFirstInstallation()
		switch result {
		case .filesPublishedStagingRetired, .filesPublishedCleanupPending: report(result.rawValue)
		case .refused: Darwin.exit(77)
		case .cleanupPending: Darwin.exit(75)
		}
		#endif
	}

	/// Writes the one closed result line, then exits zero; the caller waits for this actual helper exit before
	/// consuming the closed publication/staging response.
	private static func report(_ value: String, kind: String = "OWNED_RUNTIME_INSTALL") -> Never {
		do { try FileHandle.standardOutput.write(contentsOf: Data((kind + "|1|" + value + "\n").utf8)) }
		catch { Darwin.exit(75) }
		Darwin.exit(0)
	}
}
