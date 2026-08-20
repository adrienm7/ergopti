// Sources/ErgoptiPlus/POSIXCompatibility.swift

/**
 ==============================================================================
 MODULE: POSIX compatibility
 DESCRIPTION:
 Keeps libc entry points and owned C-string vectors stable across Swift SDK
 importer changes.

 FEATURES & RATIONALE:
 1. Binds BSD flock by symbol name because Swift 6.3 resolves the Darwin member
    as the record-lock structure rather than the libc function.
 2. Builds an owned, nil-terminated environment for posix_spawn instead of
    relying on the SDK-private `_NSGetEnviron` accessor.
 ==============================================================================
 */

import Darwin
import Foundation

@_silgen_name("flock")
private func c_flock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Applies a BSD advisory lock without depending on the SDK import spelling.
func ergoptiFlock(_ descriptor: Int32, _ operation: Int32) -> Int32 {
	c_flock(descriptor, operation)
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
