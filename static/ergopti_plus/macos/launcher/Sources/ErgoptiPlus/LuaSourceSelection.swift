// Sources/ErgoptiPlus/LuaSourceSelection.swift

// ==============================================================================
// MODULE: Lua Source Selection
// DESCRIPTION:
// Decides where the embedded Hammerspoon reads its Lua. A packaged app reads
// the signed payload under Contents/Resources. A developer build
// (ERGOPTI_DEV_SOURCE=1 bash tools/build/build_macos_app.sh) records one clone
// root in its Info.plist; the launcher then points Hammerspoon at that clone's
// static/ergopti_plus/macos, so a Reload picks up edits, and starts no Sparkle.
//
// FEATURES & RATIONALE:
// 1. Pure: the Info.plist dictionary and the file probe are passed in, so every
//    branch is tested without a bundle.
// 2. Fail fast: a key that is not a plain absolute path, or a clone without
//    init.lua, refuses the launch with a named reason; the payload is never run
//    in its place.
// 3. One spelling: the key is Identifiers.DevSource.plistKey, generated from
//    _shared/data/identifiers.json like the build script's and the release
//    guard's.
// ==============================================================================

import Foundation

/// Where the embedded runtime's Lua comes from.
enum LuaSourceSelection: Equatable {
	/// The signed payload inside the application bundle.
	case packaged(configDir: String)
	/// One repository clone recorded by a developer build.
	case developer(root: String, configDir: String)
	/// A developer key that cannot be honoured; the launch must stop.
	case refused(reason: String)

	/// The driver folder, relative to the bundle resources or the clone root.
	static let driverSubpath = "static/ergopti_plus/macos"

	/// Resolves the Lua source of one launcher bundle.
	/// - Parameters:
	///   - infoDictionary: The launcher's Info.plist dictionary.
	///   - bundlePath: Absolute path of the launcher .app bundle.
	///   - fileExists: Probe for a regular file at an absolute path.
	/// - Returns: The selection; `.refused` names what is wrong.
	static func resolve(
		infoDictionary: [String: Any]?,
		bundlePath: String,
		fileExists: (String) -> Bool
	) -> LuaSourceSelection {
		let key = Identifiers.DevSource.plistKey
		guard let value = infoDictionary?[key] else {
			return .packaged(configDir: "\(bundlePath)/Contents/Resources/\(driverSubpath)")
		}
		guard let root = value as? String, root.count > 1, root.hasPrefix("/"),
			!root.hasSuffix("/"), !root.contains("\0"), !root.contains("\n")
		else {
			return .refused(reason: "The developer source key \(key) is not a plain absolute clone path.")
		}
		let configDir = "\(root)/\(driverSubpath)"
		guard fileExists("\(configDir)/init.lua") else {
			return .refused(
				reason: "This developer build runs the Lua of \(root), but \(configDir)/init.lua is missing. "
					+ "Restore that clone or rebuild with ERGOPTI_DEV_SOURCE=1 from the clone to use."
			)
		}
		return .developer(root: root, configDir: configDir)
	}

	/// The folder holding init.lua, or nil for a refusal.
	var configDir: String? {
		switch self {
		case let .packaged(configDir), let .developer(_, configDir): return configDir
		case .refused: return nil
		}
	}

	/// The clone root of a developer build, or nil.
	var developerRoot: String? {
		if case let .developer(root, _) = self { return root }
		return nil
	}
}
