// Sources/ErgoptiPlus/MenuFontRegistration.swift

// ==============================================================================
// MODULE: Menu Font Registration
// DESCRIPTION:
// Makes the reading fonts (Configuration > Accessibility, script.reading_font)
// usable by the tray menu. The menu is built by the embedded Hammerspoon, a
// separate process, which can only name a font AppKit already knows: it has no
// call that loads a font file. The launcher therefore registers the sfnt faces
// that _shared/ui/fonts/menu_faces.json lists for the login session before it
// starts the runtime, and unregisters them when it quits.
//
// FEATURES & RATIONALE:
// 1. Session scope: a process-scoped face would stay in the launcher, which
//    draws no menu; a user-scoped one would persist in the user's font list
//    after an uninstall. CTFontManagerScope.session reaches every process of
//    the login session and ends with it.
// 2. One source: the files come from menu_faces.json, the manifest the Lua
//    menu builder and the Windows tray read; nothing here names a font.
// 3. Explicit failure: an unreadable manifest or a refused face is reported
//    with its reason; a face the session already holds (a relaunch) counts as
//    registered. The menu builder checks the face itself and logs an error
//    when it is missing, so the menu never pretends to use the font.
// 4. Injected Core Text: the registrar and the file reader are parameters, so
//    every branch is tested without registering a real font.
// ==============================================================================

import CoreText
import Foundation

/// Why the face list could not be read from menu_faces.json.
enum MenuFontManifestError: Error, Equatable, CustomStringConvertible {
	/// The manifest file could not be read.
	case unreadable(String)
	/// The manifest is not a `{ "faces": { key: { "file": … } } }` object.
	case malformed(String)

	var description: String {
		switch self {
		case let .unreadable(path): return "cannot read \(path)"
		case let .malformed(path): return "\(path) is not a menu face manifest"
		}
	}
}

/// What became of one face.
enum MenuFontOutcome: Equatable {
	/// Core Text registered the face for this session.
	case registered(URL)
	/// The session already held it (an earlier launch of the same app).
	case alreadyRegistered(URL)
	/// Core Text refused it, with its error code when it gave one.
	case refused(URL, code: Int?)
}

/// Registers and unregisters the tray menu's reading-font faces.
enum MenuFontRegistration {
	/// The manifest beside the faces.
	static let manifestName = "menu_faces.json"
	/// kCTFontManagerErrorAlreadyRegistered: the session holds this file already.
	static let alreadyRegisteredCode = 105

	/// Registers or unregisters one file; answers whether it succeeded and, if
	/// not, the Core Text error code.
	typealias FontRegistrar = (URL) -> (succeeded: Bool, errorCode: Int?)

	/// The fonts folder beside the driver tree: `<configDir>/../_shared/ui/fonts`.
	/// - Parameter configDir: The driver folder the runtime reads its Lua from.
	/// - Returns: The folder holding menu_faces.json.
	static func fontsDirectory(configDir: String) -> URL {
		return URL(fileURLWithPath: configDir, isDirectory: true)
			.deletingLastPathComponent()
			.appendingPathComponent("_shared/ui/fonts", isDirectory: true)
	}

	/// The face files menu_faces.json names, in its key order.
	/// - Parameters:
	///   - fontsDirectory: The folder holding the manifest and the faces.
	///   - readData: Reads one file.
	/// - Returns: Absolute file URLs.
	/// - Throws: MenuFontManifestError naming the manifest.
	static func faceURLs(
		fontsDirectory: URL,
		readData: (URL) throws -> Data = { try Data(contentsOf: $0) }
	) throws -> [URL] {
		let manifest = fontsDirectory.appendingPathComponent(manifestName)
		guard let data = try? readData(manifest) else {
			throw MenuFontManifestError.unreadable(manifest.path)
		}
		guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			let faces = root["faces"] as? [String: Any], !faces.isEmpty
		else { throw MenuFontManifestError.malformed(manifest.path) }
		var urls: [URL] = []
		for key in faces.keys.sorted() {
			guard let face = faces[key] as? [String: Any], let file = face["file"] as? String,
				!file.isEmpty, !file.hasPrefix("/"),
				!file.split(separator: "/").contains("..")
			else { throw MenuFontManifestError.malformed(manifest.path) }
			urls.append(fontsDirectory.appendingPathComponent(file))
		}
		return urls
	}

	/// Registers each face for the login session.
	/// - Parameters:
	///   - urls: From faceURLs(fontsDirectory:readData:).
	///   - registrar: Core Text's session registration, injected by the tests.
	/// - Returns: One outcome per face, in order.
	static func register(_ urls: [URL], registrar: FontRegistrar = sessionRegistrar) -> [MenuFontOutcome] {
		return urls.map { url in
			let result = registrar(url)
			if result.succeeded { return .registered(url) }
			if result.errorCode == alreadyRegisteredCode { return .alreadyRegistered(url) }
			return .refused(url, code: result.errorCode)
		}
	}

	/// The files a quit must unregister: those this launch registered or found
	/// already registered, never a refused one.
	/// - Parameter outcomes: From register(_:registrar:).
	/// - Returns: The files the session holds.
	static func held(_ outcomes: [MenuFontOutcome]) -> [URL] {
		return outcomes.compactMap { outcome in
			switch outcome {
			case let .registered(url), let .alreadyRegistered(url): return url
			case .refused: return nil
			}
		}
	}

	/// Core Text's session registration of one file.
	static let sessionRegistrar: FontRegistrar = { url in
		var error: Unmanaged<CFError>?
		if CTFontManagerRegisterFontsForURL(url as CFURL, .session, &error) { return (true, nil) }
		return (false, error.map { CFErrorGetCode($0.takeRetainedValue()) })
	}

	/// Core Text's session unregistration of one file.
	static let sessionUnregistrar: FontRegistrar = { url in
		var error: Unmanaged<CFError>?
		if CTFontManagerUnregisterFontsForURL(url as CFURL, .session, &error) { return (true, nil) }
		return (false, error.map { CFErrorGetCode($0.takeRetainedValue()) })
	}
}
