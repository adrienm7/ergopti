// Sources/ErgoptiPlus/POSIXCompatibility.swift

/**
 ==============================================================================
 MODULE: POSIX compatibility
 DESCRIPTION:
 Keeps libc entry points and owned C-string vectors stable across Swift SDK
 importer changes.

 FEATURES & RATIONALE:
 1. Calls BSD flock through a C shim because Swift 6.3 resolves the Darwin
    member as the record-lock structure rather than the libc function.
 2. Obtains process exit status through kqueue without exposing C macros to Swift.
 3. Builds an owned, nil-terminated environment for posix_spawn instead of
    relying on the SDK-private `_NSGetEnviron` accessor.
 ==============================================================================
 */

import CPOSIXCompatibility
import Darwin
import Foundation

/// Applies a BSD advisory lock through a normal C ABI compatibility shim.
func ergoptiFlock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
	ergopti_flock_compat(descriptor, operation)
}

/// Creates a one-shot kernel monitor that reports the target's real wait status.
func ergoptiOpenProcessExitMonitor(
	_ processIdentifier: pid_t,
	errorCode: UnsafeMutablePointer<Int32>
) -> Int32 {
	ergopti_process_exit_monitor_open(processIdentifier, errorCode)
}

/// Reads one available process-exit event without blocking the caller.
func ergoptiReadProcessExitMonitor(
	_ descriptor: Int32,
	rawStatus: UnsafeMutablePointer<Int32>,
	errorCode: UnsafeMutablePointer<Int32>
) -> Int32 {
	ergopti_process_exit_monitor_read(descriptor, rawStatus, errorCode)
}

/// Duplicates strings into one owned, nil-terminated C vector.
func duplicateCStringVector(
	_ values: [String]
) -> [UnsafeMutablePointer<CChar>?]? {
	var duplicated: [UnsafeMutablePointer<CChar>?] = []
	for value in values {
		guard let pointer = strdup(value) else {
			for case let existing? in duplicated { free(existing) }
			return nil
		}
		duplicated.append(pointer)
	}
	duplicated.append(nil)
	return duplicated
}

/// Duplicates an environment into deterministic `KEY=VALUE` entries for spawn.
func duplicateProcessEnvironment(
	_ environment: [String: String] = ProcessInfo.processInfo.environment
) -> [UnsafeMutablePointer<CChar>?]? {
	duplicateCStringVector(
		environment.map { "\($0.key)=\($0.value)" }.sorted()
	)
}
