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
		let result = OwnedRuntimeInstallerEntry.runFirstInstallation()
		switch result {
		case .filesPublishedStagingRetired, .filesPublishedCleanupPending:
			do { try FileHandle.standardOutput.write(contentsOf: Data(("OWNED_RUNTIME_INSTALL|1|" + result.rawValue + "\n").utf8)) }
			catch { Darwin.exit(75) }
			// The caller waits for this actual helper exit before consuming the closed publication/staging response.
			Darwin.exit(0)
		case .refused: Darwin.exit(77)
		case .cleanupPending: Darwin.exit(75)
		}
	}
}
