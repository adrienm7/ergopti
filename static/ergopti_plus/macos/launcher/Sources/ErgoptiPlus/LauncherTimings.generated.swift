// Sources/ErgoptiPlus/LauncherTimings.generated.swift
// AUTO-GENERATED from _shared/modules/timings/constants.toml.
// DO NOT EDIT BY HAND — run `npm run codegen:registry-constants` to refresh.

// ==============================================================================
// MODULE: Launcher Timings
// DESCRIPTION:
// The [launcher] section of the timing registry: every sleep and poll interval
// of the launcher, its fixtures and its tests, in the units the sleep APIs take.
// ==============================================================================

import Foundation

/// One registry duration; the section and key name it in diagnostics.
struct RegistryDuration: Sendable {
	let section: String
	let key: String
	let milliseconds: UInt32

	/// For usleep; the generator bounds every value to a 32-bit count.
	var microseconds: useconds_t { useconds_t(milliseconds) * 1_000 }
	/// For Thread.sleep(forTimeInterval:) and deadlines.
	var seconds: TimeInterval { TimeInterval(milliseconds) / 1_000 }
	/// For Task.sleep(nanoseconds:).
	var nanoseconds: UInt64 { UInt64(milliseconds) * 1_000_000 }
}

enum LauncherTimings {
	static let fileLockRetry = RegistryDuration(section: "launcher", key: "file_lock_retry_ms", milliseconds: 1)
	static let instanceLockRetry = RegistryDuration(section: "launcher", key: "instance_lock_retry_ms", milliseconds: 100)
	static let guardianArmPoll = RegistryDuration(section: "launcher", key: "guardian_arm_poll_ms", milliseconds: 10)
	static let guardianSingletonRetry = RegistryDuration(section: "launcher", key: "guardian_singleton_retry_ms", milliseconds: 10)
	static let leaseChildPoll = RegistryDuration(section: "launcher", key: "lease_child_poll_ms", milliseconds: 50)
	static let processTerminationGrace = RegistryDuration(section: "launcher", key: "process_termination_grace_ms", milliseconds: 50)
	static let fenceRetryFirst = RegistryDuration(section: "launcher", key: "fence_retry_first_ms", milliseconds: 50)
	static let fenceRetrySecond = RegistryDuration(section: "launcher", key: "fence_retry_second_ms", milliseconds: 100)
	static let fenceRetryThird = RegistryDuration(section: "launcher", key: "fence_retry_third_ms", milliseconds: 250)
	static let fenceRetryLast = RegistryDuration(section: "launcher", key: "fence_retry_last_ms", milliseconds: 1000)
	static let automationGuardianPoll = RegistryDuration(section: "launcher", key: "automation_guardian_poll_ms", milliseconds: 20)
	static let automationPermissionPoll = RegistryDuration(section: "launcher", key: "automation_permission_poll_ms", milliseconds: 50)
	static let uninstallLeasePoll = RegistryDuration(section: "launcher", key: "uninstall_lease_poll_ms", milliseconds: 10)
	static let automationFixtureWait = RegistryDuration(section: "launcher", key: "automation_fixture_wait_ms", milliseconds: 30000)
	static let programFixturePoll = RegistryDuration(section: "launcher", key: "program_fixture_poll_ms", milliseconds: 1)
	static let ollamaFixtureReapPoll = RegistryDuration(section: "launcher", key: "ollama_fixture_reap_poll_ms", milliseconds: 10)
	static let ollamaFixtureProgressPart = RegistryDuration(section: "launcher", key: "ollama_fixture_progress_part_ms", milliseconds: 400)
	static let ollamaFixtureStallPart = RegistryDuration(section: "launcher", key: "ollama_fixture_stall_part_ms", milliseconds: 1500)
	static let testFastPoll = RegistryDuration(section: "launcher", key: "test_fast_poll_ms", milliseconds: 1)
	static let testPoll = RegistryDuration(section: "launcher", key: "test_poll_ms", milliseconds: 10)
	static let testRecordPoll = RegistryDuration(section: "launcher", key: "test_record_poll_ms", milliseconds: 5)
	static let testGuardianSettle = RegistryDuration(section: "launcher", key: "test_guardian_settle_ms", milliseconds: 350)
	static let testGuardianRetireSettle = RegistryDuration(section: "launcher", key: "test_guardian_retire_settle_ms", milliseconds: 100)
	static let testLeaseLineInterval = RegistryDuration(section: "launcher", key: "test_lease_line_interval_ms", milliseconds: 50)
	static let testSlowSettingsRead = RegistryDuration(section: "launcher", key: "test_slow_settings_read_ms", milliseconds: 20)
}
