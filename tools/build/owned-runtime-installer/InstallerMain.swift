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
		guard CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--owned-install-first" else { Darwin.exit(64) }
		#if ERGOPTI_OWNED_IDLE_CORE
		// The live helper also provisions and starts the idle Core control service (ADR 011, WP6 install half).
		let result = OwnedRuntimeIdleServiceEntry.runFirstInstallation()
		switch result {
		case .idleCoreObservedStagingRetired, .filesPublishedServiceCleanupPending: report(result.rawValue)
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
	private static func report(_ value: String) -> Never {
		do { try FileHandle.standardOutput.write(contentsOf: Data(("OWNED_RUNTIME_INSTALL|1|" + value + "\n").utf8)) }
		catch { Darwin.exit(75) }
		Darwin.exit(0)
	}
}
