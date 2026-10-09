// Sources/ErgoptiPlus/LoginStartupWorker.swift

// ==============================================================================
// MODULE: Explicit Login Startup Settings
// DESCRIPTION:
// Registers the outer application, never its embedded keyboard driver. Merely
// starting or updating Ergopti does not register a login item or override consent.
// ==============================================================================

import Foundation
import ServiceManagement

/// Startup state is reported by macOS, including pending user approval.
enum LoginStartupState: String {
	case enabled, disabled, approval, unavailable
}

enum LoginStartupFailure: Error {
	case unconfirmed
}

/// Applies an explicit toggle through injectable operating-system boundaries.
func toggleLoginStartup(
	read: () -> LoginStartupState,
	enable: () throws -> Void,
	disable: () throws -> Void,
	requestApproval: () -> Void
) throws -> LoginStartupState {
	let before = read()
	if before == .approval { requestApproval(); return before }
	if before == .unavailable { return before }
	do {
		if before == .enabled { try disable() } else { try enable() }
	} catch {
		if read() == .approval { requestApproval(); return .approval }
		throw error
	}
	let after = read()
	if after == .approval { requestApproval() }
	if after != .approval && after != (before == .enabled ? .disabled : .enabled) {
		throw LoginStartupFailure.unconfirmed
	}
	return after
}

/// Headless settings role, dispatched before the interactive application boots.
enum LoginStartupWorker {
	static func handles(arguments: [String]) -> Bool {
		arguments.count > 1 && arguments[1] == "--login-startup"
	}

	static func run(arguments: [String]) -> Int32 {
		guard arguments.count == 3, ["status", "toggle"].contains(arguments[2]),
			Bundle.main.bundleIdentifier == kErgoptiBundleId,
			Bundle.main.bundleURL.pathExtension == "app" else { return 64 }
		guard #available(macOS 13.0, *) else {
			print(LoginStartupState.unavailable.rawValue)
			return 69
		}
		let service = SMAppService.mainApp
		let read: () -> LoginStartupState = {
			switch service.status {
			case .enabled: return .enabled
			case .notRegistered: return .disabled
			case .requiresApproval: return .approval
			case .notFound: return .unavailable
			@unknown default: return .unavailable
			}
		}
		do {
			let state: LoginStartupState
			if arguments[2] == "status" {
				state = read()
			} else {
				state = try toggleLoginStartup(
					read: read,
					enable: { try service.register() },
					disable: { try service.unregister() },
					requestApproval: { SMAppService.openSystemSettingsLoginItems() }
				)
			}
			print(state.rawValue)
			return 0
		} catch {
			LauncherLog.write("login startup setting failed: \(error)")
			return 70
		}
	}
}
