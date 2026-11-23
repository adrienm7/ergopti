// Tests/ErgoptiPlusTests/HammerspoonIconPreferenceTests.swift
// Field report 2026-11-23: the hammer stayed in the menu bar beside ErgoptiPlus' icon.
import XCTest
@testable import ErgoptiPlus

final class HammerspoonIconPreferenceTests: XCTestCase {
	/// The keys Hammerspoon 1.1.1 reads (variables.h): "MJShow…OnLaunch" names were never read.
	func testTheHiddenIconKeysAreTheOnesHammerspoonReads() {
		XCTAssertEqual(kHammerspoonHiddenIconKeys, ["MJShowMenuIconKey", "MJShowDockIconKey"])
		XCTAssertFalse(kHammerspoonHiddenIconKeys.contains { $0.hasSuffix("OnLaunch") })
	}
}
