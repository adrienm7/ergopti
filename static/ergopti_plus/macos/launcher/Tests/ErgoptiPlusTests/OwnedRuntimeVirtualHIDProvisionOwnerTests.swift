// Tests/ErgoptiPlusTests/OwnedRuntimeVirtualHIDProvisionOwnerTests.swift
// The VirtualHIDDevice daemon job is pqrs' plist under Ergopti's label; the package chain must be pqrs' own.
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeVirtualHIDProvisionOwnerTests: XCTestCase {
	/// The daemon plist of pqrs-org/Karabiner-DriverKit-VirtualHIDDevice v8.5.0 (files/LaunchDaemons).
	private let pqrs = Data("""
	<?xml version="1.0" encoding="UTF-8"?>
	<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
	<plist version="1.0">
	  <dict>
	    <key>Label</key>
	    <string>org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon</string>
	    <key>KeepAlive</key>
	    <true/>
	    <key>ProcessType</key>
	    <string>Interactive</string>
	    <key>ProgramArguments</key>
	    <array>
	      <string>/Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon</string>
	    </array>
	  </dict>
	</plist>
	""".utf8)

	private func fields(_ data: Data) throws -> [String: Any] {
		try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
	}

	func testTheJobKeepsPqrsKeysUnderErgoptisLabel() throws {
		let job = try fields(OwnedRuntimeVirtualHIDProvisionOwner.jobBytes(pqrs: pqrs))
		XCTAssertEqual(job["Label"] as? String, Identifiers.ServiceLabels.macosVirtualHid)
		XCTAssertEqual(job["ProgramArguments"] as? [String], [OwnedVirtualHIDDaemonReportReference.daemonExecutable])
		XCTAssertEqual(job["KeepAlive"] as? Bool, true)
		XCTAssertEqual(job["ProcessType"] as? String, "Interactive")
		XCTAssertEqual(Set(job.keys), ["Label", "KeepAlive", "ProcessType", "ProgramArguments"])
	}

	func testAnotherProgramOrLabelIsRefused() throws {
		var other = try fields(pqrs)
		other["ProgramArguments"] = ["/tmp/daemon"]
		XCTAssertThrowsError(try OwnedRuntimeVirtualHIDProvisionOwner.jobBytes(
			pqrs: PropertyListSerialization.data(fromPropertyList: other, format: .xml, options: 0)))
		other = try fields(pqrs)
		other["Label"] = Identifiers.ServiceLabels.macosVirtualHid
		XCTAssertThrowsError(try OwnedRuntimeVirtualHIDProvisionOwner.jobBytes(
			pqrs: PropertyListSerialization.data(fromPropertyList: other, format: .xml, options: 0)))
	}

	func testOnlyPqrsDeveloperIDInstallerChainIsAccepted() {
		let signed = """
		Package "Karabiner-DriverKit-VirtualHIDDevice-8.5.0.pkg":
		   Status: signed by a developer certificate issued by Apple for distribution
		   Notarization: trusted by the Apple notary service
		   Signed with a trusted timestamp on: 2026-01-01 00:00:00 +0000
		   Certificate Chain:
		    1. Developer ID Installer: Fumihiko Takayama (G43BCU2T37)
		    2. Developer ID Certification Authority
		    3. Apple Root CA
		"""
		XCTAssertTrue(OwnedRuntimeVirtualHIDProvisionOwner.signedByPqrs(Data(signed.utf8)))
		XCTAssertFalse(OwnedRuntimeVirtualHIDProvisionOwner.signedByPqrs(Data(signed.replacingOccurrences(of: "G43BCU2T37", with: "AAAAAAAAAA").utf8)))
		XCTAssertFalse(OwnedRuntimeVirtualHIDProvisionOwner.signedByPqrs(Data(signed.replacingOccurrences(of: "   Status: signed by a developer certificate issued by Apple for distribution\n", with: "   Status: no signature\n").utf8)))
	}
}
