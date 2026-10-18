// Sources/ErgoptiPlus/LauncherLocalization.swift

/**
 ==============================================================================
 MODULE: Launcher localization
 DESCRIPTION:
 Reads the shared driver locale catalog bundled in the application so the
 launcher's fatal alert speaks the user's language.

 FEATURES & RATIONALE:
 1. One source of truth: the same _shared/data/locales/<code>.json files the
    Lua driver uses; the launcher never carries its own copy of a string.
 2. Same language choice as the driver: the locale the driver persisted in its
    preferences domain, then the macOS preferred languages, then English.
 3. The launcher alert is the only UI left when the driver could not start. If
    the bundled catalog itself is unreadable, the caller shows its English
    developer diagnostic — the documented pre-i18n fatal-modal exception.
 ==============================================================================
 */

import CoreFoundation
import Foundation

/// Driver preference key (hs.settings namespace "ergopti.") holding the locale.
let kDriverLocalePreferenceKey = "ergopti.i18n_locale"

struct LauncherLocalization {
	let localeCode: String
	private let strings: [String: String]

	/// Loads the first readable catalog among the candidate locales.
	/// - Parameters:
	///   - localesDirectory: Bundled `_shared/data/locales` folder.
	///   - storedLocale: Locale the driver persisted, if any.
	///   - preferredLanguages: macOS preferred languages, most preferred first.
	/// - Returns: The catalog, or nil when no candidate file can be parsed.
	static func load(
		localesDirectory: String = Bundle.main.bundlePath
			+ "/Contents/Resources/static/ergopti_plus/_shared/data/locales",
		storedLocale: String? = storedDriverLocale(),
		preferredLanguages: [String] = Locale.preferredLanguages
	) -> LauncherLocalization? {
		var candidates: [String] = []
		for raw in [storedLocale].compactMap({ $0 }) + preferredLanguages + ["en"] {
			let code = String(raw.lowercased().prefix(2))
			guard code.count == 2, code.allSatisfy({ $0 >= "a" && $0 <= "z" }),
				!candidates.contains(code)
			else { continue }
			candidates.append(code)
		}
		for code in candidates {
			let path = "\(localesDirectory)/\(code).json"
			guard let data = FileManager.default.contents(atPath: path),
				let object = try? JSONSerialization.jsonObject(with: data),
				let strings = object as? [String: String]
			else { continue }
			return LauncherLocalization(localeCode: code, strings: strings)
		}
		return nil
	}

	/// Reads the locale the driver persisted under its own preferences domain.
	static func storedDriverLocale() -> String? {
		return CFPreferencesCopyAppValue(
			kDriverLocalePreferenceKey as CFString,
			kEmbeddedHammerspoonBundleId as CFString
		) as? String
	}

	/// Fills numbered placeholders from the original catalog text once, keeping
	/// braces inside argument values literal and unprovided slots unchanged.
	func text(_ key: String, _ arguments: [String] = []) -> String? {
		guard let value = strings[key], !value.isEmpty else { return nil }
		let components = value.components(separatedBy: "{")
		var rendered = components[0]
		for component in components.dropFirst() {
			guard let closing = component.firstIndex(of: "}"),
				let position = Int(component[..<closing]), position > 0,
				position <= arguments.count, component[..<closing] == String(position)
			else {
				rendered += "{" + component
				continue
			}
			rendered += arguments[position - 1]
			rendered += String(component[component.index(after: closing)...])
		}
		return rendered
	}
}

/// User-facing alert text for a refused log folder, or nil without a catalog.
func logFolderRefusalAlertText(
	_ failure: LogDirectoryFailure,
	localization: LauncherLocalization?
) -> String? {
	return localization?.text(
		"launcher.log_folder_refused.\(failure.refusal.localizationKey)",
		[failure.path, failure.refusal.detail]
	)
}
