// Tests/ErgoptiPlusTests/ScreenVisionMatcherTests.swift

// ==============================================================================
// MODULE: Screen Vision Matcher Tests
// DESCRIPTION:
// Replays _shared/tests/corpus/keep_awake/auto_click_match_vectors.json, which
// the macOS and Linux Lua suites replay through the shared matcher and the
// Windows suite through its AutoHotkey twin, through the launcher's Swift
// port. A port that rounded, scaled or ranked candidates differently would
// find another button, or the same one at another tolerance, than Linux and
// Windows.
// ==============================================================================

import Foundation
import XCTest
@testable import ErgoptiPlus

final class ScreenVisionMatcherTests: XCTestCase {

	private static let parkMillerMultiplier = 16_807
	private static let parkMillerModulus = 2_147_483_647

	private func corpus() throws -> [String: Any] {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<4 { url.deleteLastPathComponent() }
		url.appendPathComponent("../_shared/tests/corpus/keep_awake/auto_click_match_vectors.json")
		let data = try Data(contentsOf: url.standardizedFileURL)
		return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
	}

	private func template(_ corpus: [String: Any], _ name: String) throws -> ScreenVisionGray {
		let palette = try XCTUnwrap(corpus["palette"] as? [String: Int])
		let rows = try XCTUnwrap((corpus["templates"] as? [String: [String]])?[name])
		var pixels: [Int] = []
		for row in rows {
			for character in row { pixels.append(try XCTUnwrap(palette[String(character)])) }
		}
		return ScreenVisionGray(width: rows[0].count, height: rows.count, pixels: pixels)
	}

	private func clamp(_ value: Int) -> Int { return min(255, max(0, value)) }

	private func addNoise(_ image: inout ScreenVisionGray, _ noise: [String: Any]?) {
		guard let noise = noise, let amplitude = noise["amplitude"] as? Int, amplitude > 0,
			var state = noise["seed"] as? Int
		else { return }
		let span = 2 * amplitude + 1
		for index in 0..<image.pixels.count {
			state = (state * Self.parkMillerMultiplier) % Self.parkMillerModulus
			image.pixels[index] = clamp(image.pixels[index] + state % span - amplitude)
		}
	}

	private func scene(_ corpus: [String: Any], _ recipe: [String: Any]) throws -> ScreenVisionGray {
		let width = try XCTUnwrap(recipe["width"] as? Int)
		let height = try XCTUnwrap(recipe["height"] as? Int)
		let background = try XCTUnwrap(recipe["background"] as? Int)
		var image = ScreenVisionGray(width: width, height: height,
			pixels: [Int](repeating: background, count: width * height))
		addNoise(&image, recipe["noise"] as? [String: Any])
		for paste in try XCTUnwrap(recipe["pastes"] as? [[String: Any]]) {
			let name = try XCTUnwrap(paste["template"] as? String)
			let factor = try XCTUnwrap((paste["scale"] as? NSNumber)?.doubleValue)
			let t = try XCTUnwrap(ScreenVisionMatcher.scale(try template(corpus, name), by: factor))
			let px = try XCTUnwrap(paste["x"] as? Int)
			let py = try XCTUnwrap(paste["y"] as? Int)
			let delta = try XCTUnwrap(paste["delta"] as? Int)
			for y in 0..<t.height {
				for x in 0..<t.width {
					image.pixels[(py + y) * width + px + x] = clamp(t.pixels[y * t.width + x] + delta)
				}
			}
		}
		addNoise(&image, recipe["overlay_noise"] as? [String: Any])
		return image
	}

	private func options(_ corpus: [String: Any], threshold: Double?) throws -> ScreenVisionMatchOptions {
		let raw = try XCTUnwrap(corpus["options"] as? [String: Any])
		return ScreenVisionMatchOptions(
			threshold: threshold ?? (raw["threshold"] as! NSNumber).doubleValue,
			scales: (raw["scales"] as! [NSNumber]).map { $0.doubleValue },
			coarseMinPx: raw["coarse_min_px"] as! Int,
			coarseMargin: (raw["coarse_margin"] as! NSNumber).doubleValue,
			coarseCandidates: raw["coarse_candidates"] as! Int)
	}

	func testReplaysEveryCorpusScene() throws {
		let corpus = try corpus()
		let vectors = try XCTUnwrap(corpus["vectors"] as? [[String: Any]])
		XCTAssertGreaterThanOrEqual(vectors.count, 9)
		for vector in vectors {
			let id = vector["id"] as! String
			let image = try scene(corpus, try XCTUnwrap(vector["scene"] as? [String: Any]))
			let templateScale = (vector["template_scale"] as? NSNumber)?.doubleValue ?? 1
			let base = try template(corpus, vector["template"] as! String)
			let t = try XCTUnwrap(ScreenVisionMatcher.scale(base, by: templateScale))
			let threshold = (vector["threshold"] as? NSNumber)?.doubleValue
			let result = ScreenVisionMatcher.find(image, t, try options(corpus, threshold: threshold))
			if let expect = vector["expect"] as? [String: Any] {
				let hit = try XCTUnwrap(result.hit, "\(id) must match")
				XCTAssertEqual(hit.x, expect["x"] as? Int, "\(id) x")
				XCTAssertEqual(hit.y, expect["y"] as? Int, "\(id) y")
				XCTAssertEqual(hit.width, expect["width"] as? Int, "\(id) width")
				XCTAssertEqual(hit.height, expect["height"] as? Int, "\(id) height")
				XCTAssertEqual(hit.scale, (expect["scale"] as? NSNumber)?.doubleValue, "\(id) scale")
			} else {
				XCTAssertNil(result.hit, "\(id) must not match")
			}
			if let reason = vector["reason"] as? String {
				XCTAssertEqual(reason, "template_uniform", "\(id) the only refusal")
				XCTAssertTrue(result.uniform, "\(id) uniform")
			}
			if let near = (vector["score_near"] as? NSNumber)?.doubleValue {
				let best = ScreenVisionMatcher.find(image, t, try options(corpus, threshold: 0.01))
				let score = try XCTUnwrap(best.hit?.score, "\(id) best score")
				XCTAssertLessThan(abs(score - near), 1e-6, "\(id) score \(score)")
			}
		}
	}

	func testRoundsGrayAsTheSharedModule() {
		XCTAssertEqual(ScreenVisionMatcher.gray(255, 0, 255), 105)
		XCTAssertNil(ScreenVisionMatcher.scale(ScreenVisionGray(width: 2, height: 2, pixels: [1, 2, 3, 4]), by: 3))
		XCTAssertTrue(ScreenVisionMatcher.isUniform(ScreenVisionGray(width: 2, height: 2, pixels: [9, 9, 9, 9])))
	}
}
