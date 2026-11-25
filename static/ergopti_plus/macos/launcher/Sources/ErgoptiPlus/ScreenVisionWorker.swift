// Sources/ErgoptiPlus/ScreenVisionWorker.swift

// ==============================================================================
// MODULE: Screen Vision Worker
// DESCRIPTION:
// Headless mode of the signed ErgoptiPlus executable for the macOS screen
// vision service (docs/design/screen-vision.md): it captures a window or a
// screen region, finds library images in it, reads its text with the Vision
// framework, and converts an imported image to the library's PNG. One JSON
// request arrives on stdin and one JSON answer leaves on stdout, as the
// Keychain worker does; macos/platform/vision/screen_vision.lua is its caller.
//
// FEATURES & RATIONALE:
// 1. Native speed: Hammerspoon's Lua 5.4 took about 0.8 s per scale to match
//    one button in an 800 x 600 window; the Swift port of the shared matcher
//    (ScreenVisionMatcher.swift) does three scales of a 1600 x 1000 window in
//    about 0.4 s, and a Retina capture is halved first, so a tick stays inside
//    its 700 ms.
// 2. Permission first: without Screen Recording, CGWindowListCreateImage
//    returns the desktop wallpaper rather than failing, so every capture asks
//    CGPreflightScreenCaptureAccess and answers "capture_permission_missing".
// 3. Vision OCR: accurate recognition with language correction, the
//    languages the caller asks for, and automatic language detection from
//    macOS 13. Word boxes come from each candidate's ranges, converted from
//    Vision's normalised bottom-left space to image pixels.
// 4. Imports go through ImageIO, so every format macOS decodes (PNG, JPEG,
//    HEIC, TIFF, GIF's first frame, BMP, WebP from macOS 11) becomes a PNG; any
//    other file is "import_unsupported_format".
// 5. Private files: captures kept for a later call are written where the
//    caller says (its private cache folder); no recognised text is logged.
// ==============================================================================

import CoreGraphics
import Darwin
import Foundation
import ImageIO
import Vision

let kScreenVisionFlag = "--screen-vision"

private let kScreenVisionMaximumRequestBytes = 1_048_576
private let kScreenVisionPNGType = "public.png" as CFString

enum ScreenVisionWorkerExit: Int32 {
	case success = 0
	case invalidArguments = 64
	case inputFailure = 65
	case outputFailure = 74
}

/// A captured image with where it was on screen.
struct ScreenVisionCapture {
	let gray: ScreenVisionGray
	let cgImage: CGImage
	let frame: CGRect
	let scale: Double
}

enum ScreenVisionWorker {

	// ======================================
	// ======= 1/ Entry =====================
	// ======================================

	static func handles(arguments: [String]) -> Bool {
		return arguments.count == 2 && arguments[1] == kScreenVisionFlag
	}

	static func run(arguments: [String]) -> Int32 {
		guard handles(arguments: arguments) else { return ScreenVisionWorkerExit.invalidArguments.rawValue }
		let data = FileHandle.standardInput.readData(ofLength: kScreenVisionMaximumRequestBytes + 1)
		guard !data.isEmpty, data.count <= kScreenVisionMaximumRequestBytes,
			let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
		else { return ScreenVisionWorkerExit.inputFailure.rawValue }
		let answer = handle(request: request)
		guard JSONSerialization.isValidJSONObject(answer),
			let output = try? JSONSerialization.data(withJSONObject: answer)
		else { return ScreenVisionWorkerExit.outputFailure.rawValue }
		FileHandle.standardOutput.write(output)
		return ScreenVisionWorkerExit.success.rawValue
	}

	/// Answers one request; every refusal is { ok = false, reason }.
	static func handle(request: [String: Any]) -> [String: Any] {
		switch request["op"] as? String {
		case "availability":
			var capture: [String: Any] = ["ok": true]
			if !hasCapturePermission() { capture = ["ok": false, "reason": "capture_permission_missing"] }
			return ["ok": true, "capture": capture, "ocr": ["ok": true]]
		case "scan":
			return scan(request)
		case "capture":
			return capture(request)
		case "match":
			return matchFile(request)
		case "ocr":
			return recognizeFile(request)
		case "import":
			return importImage(request)
		default:
			return refusal("invalid_request")
		}
	}

	private static func refusal(_ reason: String) -> [String: Any] {
		return ["ok": false, "reason": reason]
	}

	// ======================================
	// ======= 2/ Capture ===================
	// ======================================

	static func hasCapturePermission() -> Bool {
		return CGPreflightScreenCaptureAccess()
	}

	/// The on-screen bounds of a window, in points.
	private static func windowBounds(_ id: CGWindowID) -> CGRect? {
		guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
			let first = info.first,
			let raw = first[kCGWindowBounds as String] as? NSDictionary
		else { return nil }
		return CGRect(dictionaryRepresentation: raw as CFDictionary)
	}

	/// Captures the window or rectangle a request names.
	static func captureTarget(_ request: [String: Any]) -> (ScreenVisionCapture?, String?) {
		guard hasCapturePermission() else { return (nil, "capture_permission_missing") }
		let image: CGImage?
		let frame: CGRect
		if let id = (request["window_id"] as? NSNumber)?.uint32Value {
			guard let bounds = windowBounds(CGWindowID(id)) else { return (nil, "no_foreground_window") }
			frame = bounds
			image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(id),
				[.boundsIgnoreFraming, .bestResolution])
		} else if let rect = request["rect"] as? [String: Any],
			let x = (rect["x"] as? NSNumber)?.doubleValue, let y = (rect["y"] as? NSNumber)?.doubleValue,
			let w = (rect["width"] as? NSNumber)?.doubleValue, let h = (rect["height"] as? NSNumber)?.doubleValue {
			frame = CGRect(x: x, y: y, width: w, height: h)
			image = CGWindowListCreateImage(frame, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
		} else {
			return (nil, "invalid_request")
		}
		guard let captured = image, captured.width > 0, captured.height > 0, frame.width > 0 else {
			return (nil, "capture_refused")
		}
		guard let gray = grayImage(captured) else { return (nil, "capture_unsupported_visual") }
		return (ScreenVisionCapture(gray: gray, cgImage: captured, frame: frame,
			scale: Double(captured.width) / Double(frame.width)), nil)
	}

	/// Draws an image into 8-bit RGBA and turns it into the shared gray.
	static func grayImage(_ image: CGImage) -> ScreenVisionGray? {
		let width = image.width
		let height = image.height
		var rgba = [UInt8](repeating: 0, count: width * height * 4)
		let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
			guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
				bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
			else { return false }
			context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
			return true
		}
		guard drawn else { return nil }
		var pixels = [Int](repeating: 0, count: width * height)
		for index in 0..<(width * height) {
			let at = index * 4
			pixels[index] = ScreenVisionMatcher.gray(Int(rgba[at]), Int(rgba[at + 1]), Int(rgba[at + 2]))
		}
		return ScreenVisionGray(width: width, height: height, pixels: pixels)
	}

	private static func frameJSON(_ capture: ScreenVisionCapture) -> [String: Any] {
		return ["x": Double(capture.frame.origin.x), "y": Double(capture.frame.origin.y),
			"width": Double(capture.frame.width), "height": Double(capture.frame.height)]
	}

	private static func writePNG(_ image: CGImage, to path: String) -> Bool {
		guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
			kScreenVisionPNGType, 1, nil)
		else { return false }
		CGImageDestinationAddImage(destination, image, nil)
		return CGImageDestinationFinalize(destination)
	}

	private static func readImage(_ path: String) -> CGImage? {
		guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
			CGImageSourceGetCount(source) > 0
		else { return nil }
		return CGImageSourceCreateImageAtIndex(source, 0, nil)
	}

	static func capture(_ request: [String: Any]) -> [String: Any] {
		let (captured, reason) = captureTarget(request)
		guard let capture = captured else { return refusal(reason ?? "capture_refused") }
		guard let out = request["out_path"] as? String, writePNG(capture.cgImage, to: out) else {
			return refusal("capture_refused")
		}
		return ["ok": true, "frame": frameJSON(capture), "scale": capture.scale,
			"width": capture.gray.width, "height": capture.gray.height, "source": out]
	}

	// ======================================
	// ======= 3/ Matching ==================
	// ======================================

	private static func matchOptions(_ raw: [String: Any]?) -> ScreenVisionMatchOptions? {
		guard let raw = raw,
			let threshold = (raw["threshold"] as? NSNumber)?.doubleValue,
			let scales = (raw["scales"] as? [NSNumber])?.map({ $0.doubleValue }), !scales.isEmpty,
			let minPx = raw["coarse_min_px"] as? Int,
			let margin = (raw["coarse_margin"] as? NSNumber)?.doubleValue,
			let candidates = raw["coarse_candidates"] as? Int
		else { return nil }
		return ScreenVisionMatchOptions(threshold: threshold, scales: scales, coarseMinPx: minPx,
			coarseMargin: margin, coarseCandidates: candidates)
	}

	/// Finds every template of a request in a gray image; hits are in that image's pixels.
	private static func match(_ gray: ScreenVisionGray, _ request: [String: Any]) -> ([[String: Any]], [String: String])? {
		guard let options = matchOptions(request["options"] as? [String: Any]) else { return nil }
		var hits: [[String: Any]] = []
		var refused: [String: String] = [:]
		for template in (request["templates"] as? [[String: Any]]) ?? [] {
			guard let id = template["id"] as? String else { continue }
			guard let path = template["path"] as? String, let image = readImage(path),
				let templateGray = grayImage(image)
			else {
				refused[id] = "template_unreadable"
				continue
			}
			var perTemplate = options
			if let threshold = (template["threshold"] as? NSNumber)?.doubleValue { perTemplate.threshold = threshold }
			let result = ScreenVisionMatcher.find(gray, templateGray, perTemplate)
			if let hit = result.hit {
				hits.append(["id": id, "x": hit.x, "y": hit.y, "width": hit.width, "height": hit.height,
					"score": hit.score, "scale": hit.scale])
			} else if result.uniform {
				refused[id] = "template_uniform"
			}
		}
		return (hits, refused)
	}

	/// The image a match runs on: a Retina capture halved to one pixel per point.
	private static func matchImage(_ capture: ScreenVisionCapture) -> (ScreenVisionGray, Double) {
		if capture.scale >= 2, let half = ScreenVisionMatcher.halve(capture.gray) {
			return (half, capture.scale / 2)
		}
		return (capture.gray, capture.scale)
	}

	static func matchFile(_ request: [String: Any]) -> [String: Any] {
		guard let source = request["source"] as? String, let image = readImage(source),
			let gray = grayImage(image)
		else { return refusal("capture_refused") }
		guard let matched = match(gray, request) else { return refusal("invalid_request") }
		return ["ok": true, "hits": matched.0, "refused": matched.1, "scale": 1]
	}

	// ======================================
	// ======= 4/ Text recognition ==========
	// ======================================

	/// Reads the words of an image, boxes in its pixels, one line id per observation.
	static func recognize(_ image: CGImage, _ ocr: [String: Any]) -> ([[String: Any]]?, String?) {
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = .accurate
		request.usesLanguageCorrection = true
		if let languages = ocr["languages"] as? [String], !languages.isEmpty {
			request.recognitionLanguages = languages
		}
		if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
		let handler = VNImageRequestHandler(cgImage: image, options: [:])
		do {
			try handler.perform([request])
		} catch {
			return (nil, "ocr_failed")
		}
		let width = Double(image.width)
		let height = Double(image.height)
		var words: [[String: Any]] = []
		for (lineIndex, observation) in (request.results ?? []).enumerated() {
			guard let candidate = observation.topCandidates(1).first else { continue }
			let text = candidate.string
			var cursor = text.startIndex
			while cursor < text.endIndex {
				guard let start = text[cursor...].firstIndex(where: { !$0.isWhitespace }) else { break }
				let end = text[start...].firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
				let range = start..<end
				let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
				words.append([
					"text": String(text[range]),
					"x": Int((box.minX * width).rounded()),
					"y": Int(((1 - box.maxY) * height).rounded()),
					"width": Int((box.width * width).rounded()),
					"height": Int((box.height * height).rounded()),
					"confidence": Double(candidate.confidence),
					"line": String(lineIndex + 1),
				])
				cursor = end
			}
		}
		return (words, nil)
	}

	static func recognizeFile(_ request: [String: Any]) -> [String: Any] {
		guard let source = request["source"] as? String, let image = readImage(source) else {
			return refusal("ocr_failed")
		}
		let (words, reason) = recognize(image, (request["ocr"] as? [String: Any]) ?? [:])
		guard let found = words else { return refusal(reason ?? "ocr_failed") }
		return ["ok": true, "words": found]
	}

	// ======================================
	// ======= 5/ Scan and import ===========
	// ======================================

	/// Captures a window, matches its templates and, when asked, reads its text.
	static func scan(_ request: [String: Any]) -> [String: Any] {
		let (captured, reason) = captureTarget(request)
		guard let capture = captured else { return refusal(reason ?? "capture_refused") }
		let (gray, matchScale) = matchImage(capture)
		guard let matched = match(gray, request) else { return refusal("invalid_request") }
		var answer: [String: Any] = ["ok": true, "frame": frameJSON(capture), "scale": matchScale,
			"width": gray.width, "height": gray.height, "hits": matched.0, "refused": matched.1]
		if let ocr = request["ocr"] as? [String: Any] {
			let (words, ocrReason) = recognize(capture.cgImage, ocr)
			// Words are in capture pixels; bring them to the matched image's.
			let ratio = capture.scale / matchScale
			answer["words"] = (words ?? []).map { word -> [String: Any] in
				var scaled = word
				for key in ["x", "y", "width", "height"] {
					scaled[key] = Int((Double(word[key] as! Int) / ratio).rounded())
				}
				return scaled
			}
			if let ocrReason = ocrReason { answer["text_reason"] = ocrReason }
		}
		return answer
	}

	/// Converts an image file of any format macOS decodes into the library's PNG.
	static func importImage(_ request: [String: Any]) -> [String: Any] {
		guard let path = request["path"] as? String, let out = request["out_path"] as? String else {
			return refusal("invalid_request")
		}
		guard let image = readImage(path), let gray = grayImage(image) else {
			return refusal("import_unsupported_format")
		}
		if ScreenVisionMatcher.isUniform(gray) { return refusal("template_uniform") }
		guard writePNG(image, to: out) else { return refusal("import_write_failed") }
		return ["ok": true, "width": image.width, "height": image.height]
	}
}
