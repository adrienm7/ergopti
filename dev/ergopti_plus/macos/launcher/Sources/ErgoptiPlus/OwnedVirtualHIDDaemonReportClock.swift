// Sources/ErgoptiPlus/OwnedVirtualHIDDaemonReportClock.swift
import Darwin

enum OwnedVirtualHIDDaemonReportClock {
	static func now() -> UInt64? {
		var value = timespec()
		guard clock_gettime(CLOCK_MONOTONIC, &value) == 0, value.tv_sec >= 0,
			value.tv_nsec >= 0, value.tv_nsec < 1_000_000_000 else { return nil }
		let seconds = UInt64(value.tv_sec), fraction = UInt64(value.tv_nsec)
		guard seconds <= (UInt64.max - fraction) / 1_000_000_000 else { return nil }
		return seconds * 1_000_000_000 + fraction
	}
	static func remains(_ start: UInt64, limit: UInt64 = 2_000_000_000) -> Bool {
		guard let now = now(), now >= start else { return false }; return now - start < limit
	}
}
