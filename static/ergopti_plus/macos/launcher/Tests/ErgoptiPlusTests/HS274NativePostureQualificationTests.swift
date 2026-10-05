// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274NativePostureQualificationTests.swift
//
// Public SDK observations qualify diagnostic samples only. Console property
// names come from private XNU keys, not a supported production permission ABI.
// Neither running this probe nor an active display proves an awake interval.

import CoreFoundation
import CoreGraphics
import Darwin
import Foundation
import IOKit
import XCTest

final class HS274NativePostureQualificationTests: XCTestCase {

	private struct DisplayFact {
		let identifier: CGDirectDisplayID
		let online: Bool
		let active: Bool
		let asleep: Bool
	}

	private let maximum = 64
	private let caller: UInt32 = 501

	private func session(_ locked: Any = false, uid: Any = UInt32(501)) -> [String: Any] {
		["kCGSSessionUserIDKey": uid, "kCGSSessionOnConsoleKey": true,
			"kCGSessionLoginDoneKey": true, "CGSSessionScreenIsLocked": locked]
	}

	private func registry(_ row: [String: Any], policy: Any = false) -> [String: Any] {
		["IOConsoleLocked": policy, "IOConsoleUsers": [row]]
	}

	func testConsoleRequiresExplicitTypedBooleans() {
		XCTAssertEqual(console(registry(session()), session(), caller), false)
		XCTAssertEqual(console(registry(session(true), policy: true), session(true), caller), true)
		for invalid in ([NSNumber(value: 0), "false", NSNull()] as [Any]) {
			XCTAssertNil(console(registry(session(invalid)), session(), caller))
			XCTAssertNil(console(registry(session(), policy: invalid), session(), caller))
			XCTAssertNil(console(registry(session()), session(invalid), caller))
		}
		var missing = session()
		missing.removeValue(forKey: "CGSSessionScreenIsLocked")
		XCTAssertNil(console(registry(missing), session(), caller))
		XCTAssertNil(console(registry(session()), missing, caller))
		XCTAssertNil(console(["IOConsoleUsers": [session()]], session(), caller))
	}

	func testConsoleRequiresOneExactCurrentSession() {
		XCTAssertNil(console(registry(session(uid: UInt32(502))), session(), caller))
		XCTAssertNil(console(registry(session()), session(uid: UInt32(502)), caller))
		XCTAssertNil(console(["IOConsoleLocked": false, "IOConsoleUsers": [session(), session()]], session(), caller))
		for key in ["kCGSSessionOnConsoleKey", "kCGSessionLoginDoneKey", "kCGSSessionUserIDKey"] {
			var incomplete = session()
			incomplete.removeValue(forKey: key)
			XCTAssertNil(console(registry(incomplete), session(), caller))
			XCTAssertNil(console(registry(session()), incomplete, caller))
		}
		XCTAssertNil(console(registry(session(uid: true)), session(), caller))
		XCTAssertNil(console(registry(session(uid: 501.5)), session(), caller))
		XCTAssertNil(console(registry(session()), nil, caller))
		XCTAssertNil(console(nil, session(), caller))
	}

	func testConsoleContradictionsAndIncompleteLoginRemainUnknown() {
		XCTAssertNil(console(registry(session(), policy: true), session(), caller))
		XCTAssertNil(console(registry(session(true), policy: false), session(true), caller))
		XCTAssertNil(console(registry(session()), session(true), caller))
		var incomplete = session()
		incomplete["kCGSessionLoginDoneKey"] = false
		XCTAssertNil(console(registry(incomplete), session(), caller))
		var absent = session()
		absent["kCGSSessionOnConsoleKey"] = false
		XCTAssertNil(console(registry(absent), session(), caller))
		XCTAssertNil(console(["IOConsoleLocked": false, "IOConsoleUsers": Array(repeating: session(), count: maximum + 1)], session(), caller))
	}

	func testDisplaySampleRequiresStableBoundedInventory() {
		let awake = DisplayFact(identifier: 1, online: true, active: true, asleep: false)
		let asleep = DisplayFact(identifier: 2, online: true, active: false, asleep: true)
		let mirror = DisplayFact(identifier: 3, online: true, active: false, asleep: false)
		XCTAssertEqual(drawable([1], [awake], [1]), true)
		XCTAssertEqual(drawable([2], [asleep], [2]), false)
		XCTAssertEqual(drawable([1, 3], [awake, mirror], [3, 1]), true)
		XCTAssertNil(drawable([3], [mirror], [3]))
		XCTAssertNil(drawable([], [], []))
		XCTAssertNil(drawable([1], [awake], [2]))
		XCTAssertNil(drawable([1, 1], [awake, awake], [1, 1]))
		XCTAssertNil(drawable([1, 2], [awake], [1, 2]))
		XCTAssertNil(drawable(Array(repeating: 1, count: maximum + 1), [], []))
		XCTAssertNil(drawable([1], [DisplayFact(identifier: 1, online: false, active: true, asleep: false)], [1]))
		XCTAssertNil(drawable([1], [DisplayFact(identifier: 1, online: true, active: true, asleep: true)], [1]))
	}

	func testActualSDKPostureSamplesPreserveUnknowns() {
		let root = IORegistryGetRootEntry(mach_port_t(0))
		XCTAssertNotEqual(root, io_registry_entry_t(0))
		guard root != 0 else { return }
		defer { XCTAssertEqual(IOObjectRelease(root), KERN_SUCCESS) }
		let first = rootProperties(root)
		let currentFirst = CGSessionCopyCurrentDictionary() as? [String: Any]
		let displayBefore = onlineDisplays()
		let displays = displayBefore?.map {
			DisplayFact(identifier: $0, online: CGDisplayIsOnline($0) != 0,
				active: CGDisplayIsActive($0) != 0, asleep: CGDisplayIsAsleep($0) != 0)
		} ?? []
		let displayAfter = onlineDisplays()
		let currentLast = CGSessionCopyCurrentDictionary() as? [String: Any]
		let last = rootProperties(root)
		XCTAssertEqual(first.status, KERN_SUCCESS)
		XCTAssertEqual(last.status, KERN_SUCCESS)
		let firstLock = console(first.properties, currentFirst, UInt32(getuid()))
		let lastLock = console(last.properties, currentLast, UInt32(getuid()))
		let lock = firstLock == lastLock ? firstLock : nil
		let display = displayBefore.flatMap { before in
			displayAfter.flatMap { drawable(before, displays, $0) }
		}
		// No initial authoritative system-awake accessor has been established.
		let systemAwake: Bool? = nil
		XCTAssertNil(systemAwake)
		func classify(_ value: Bool?) -> String {
			value.map { $0 ? "observed_true" : "observed_false" } ?? "unknown"
		}
		// Only closed classifications leave this test; no session dictionary,
		// username, UID, audit ID, display ID or private path enters CI output.
		print("Native posture diagnostic console_locked=" + classify(lock)
			+ " drawable=" + classify(display) + " initial_system_awake=unknown"
			+ " scope=sampled_observation interval_continuity=unqualified")
	}

	/// CFBoolean is distinct from a CFNumber containing zero or one.
	private func boolean(_ value: Any?) -> Bool? {
		guard let number = value as? NSNumber,
			CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
		return number.boolValue
	}

	private func userID(_ value: Any?) -> UInt32? {
		guard let number = value as? NSNumber,
			CFGetTypeID(number) == CFNumberGetTypeID(),
			number.doubleValue >= 0, number.doubleValue <= Double(UInt32.max),
			number.doubleValue == Double(number.uint64Value) else { return nil }
		return UInt32(number.uint64Value)
	}

	/// UID correlation identifies the selected console row, not a process
	/// incarnation. Private keys and independent reads admit no native authority.
	private func console(_ properties: [String: Any]?, _ current: [String: Any]?, _ uid: UInt32) -> Bool? {
		guard let properties, let current,
			let policy = boolean(properties["IOConsoleLocked"]),
			let rows = properties["IOConsoleUsers"] as? [[String: Any]],
			!rows.isEmpty, rows.count <= maximum,
			boolean(current["kCGSSessionOnConsoleKey"]) == true,
			boolean(current["kCGSessionLoginDoneKey"]) == true,
			userID(current["kCGSSessionUserIDKey"]) == uid,
			let currentLock = boolean(current["CGSSessionScreenIsLocked"]) else { return nil }
		var locks: [Bool] = []
		for row in rows {
			guard let onConsole = boolean(row["kCGSSessionOnConsoleKey"]) else { return nil }
			if !onConsole { continue }
			guard boolean(row["kCGSessionLoginDoneKey"]) == true,
				userID(row["kCGSSessionUserIDKey"]) == uid,
				let locked = boolean(row["CGSSessionScreenIsLocked"]) else { return nil }
			locks.append(locked)
		}
		guard locks.count == 1, locks[0] == policy, currentLock == policy else { return nil }
		return policy
	}

	/// Mirrored online displays need not be drawable. Empty or changed identity
	/// inventories and contradictory flags cannot establish either observation.
	private func drawable(_ before: [CGDirectDisplayID], _ facts: [DisplayFact], _ after: [CGDirectDisplayID]) -> Bool? {
		guard !before.isEmpty, before.count <= maximum,
			before.sorted() == after.sorted(), Set(before).count == before.count,
			!before.contains(0), facts.count == before.count,
			facts.map({ $0.identifier }).sorted() == before.sorted(),
			facts.allSatisfy({ $0.online && !($0.active && $0.asleep) }) else { return nil }
		if facts.contains(where: { $0.active }) { return true }
		if facts.allSatisfy({ $0.asleep }) { return false }
		return nil
	}

	private func rootProperties(_ root: io_registry_entry_t) -> (status: kern_return_t, properties: [String: Any]?) {
		var raw: Unmanaged<CFMutableDictionary>?
		let status = IORegistryEntryCreateCFProperties(root, &raw, kCFAllocatorDefault, 0)
		// Consume every returned retained dictionary, including error returns.
		let dictionary = raw?.takeRetainedValue()
		return (status, status == KERN_SUCCESS ? dictionary as? [String: Any] : nil)
	}

	private func onlineDisplays() -> [CGDirectDisplayID]? {
		var count: UInt32 = 0
		guard CGGetOnlineDisplayList(0, nil, &count) == .success,
			count > 0, count <= UInt32(maximum) else { return nil }
		var displays = Array(repeating: CGDirectDisplayID(0), count: Int(count))
		var returned: UInt32 = 0
		let status = displays.withUnsafeMutableBufferPointer {
			CGGetOnlineDisplayList(count, $0.baseAddress, &returned)
		}
		guard status == .success, returned == count else { return nil }
		return displays
	}
}
