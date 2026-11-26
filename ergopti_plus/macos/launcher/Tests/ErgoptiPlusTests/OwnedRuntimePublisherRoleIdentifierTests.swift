// Tests/ErgoptiPlusTests/OwnedRuntimePublisherRoleIdentifierTests.swift

// ==============================================================================
// MODULE: Owned Runtime Publisher Role Identifier Tests
// DESCRIPTION:
// The publisher roles are the code-signing identifiers every owned-runtime
// trust check names. A Swift raw value must be a literal, so the enum keeps
// its own spelling; this test pins each one to the single declaration in
// _shared/core/text/data/identifiers.json (Identifiers.generated.swift), so a renamed
// signing id cannot leave a role checking the old name.
// ==============================================================================

import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimePublisherRoleIdentifierTests: XCTestCase {
	func testEveryRoleRawValueIsItsDeclaredIdentifier() {
		let declared: [OwnedRuntimePublisherSignature.Role: String] = [
			.launcher: Identifiers.BundleIds.launcher,
			.hammerspoon: Identifiers.BundleIds.hammerspoon,
			.installer: Identifiers.SigningIds.runtimeInstaller,
			.core: Identifiers.SigningIds.remapCore,
			.console: Identifiers.SigningIds.remapConsole,
			.cli: Identifiers.SigningIds.remapCli,
			.installedSource: Identifiers.SigningIds.installedPhysicalSource,
		]
		for (role, identifier) in declared {
			XCTAssertEqual(role.rawValue, identifier, "\(role) names a signing id other than its declaration")
		}
		XCTAssertEqual(Set(declared.values).count, declared.count, "two roles share one signing id")
	}
}
