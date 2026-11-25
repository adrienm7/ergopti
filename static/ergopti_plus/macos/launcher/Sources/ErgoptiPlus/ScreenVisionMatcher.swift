// Sources/ErgoptiPlus/ScreenVisionMatcher.swift

// ==============================================================================
// MODULE: Screen Vision Matcher
// DESCRIPTION:
// Swift port of _shared/shortcuts/engine/keep_awake/auto_click_matcher.lua, the matcher
// the Linux driver runs in LuaJIT and the Windows driver in its own twin. The
// macOS driver runs it here, in the signed launcher, because Hammerspoon's
// Lua 5.4 took about 0.8 s per scale for an 800 x 600 window.
//
// FEATURES & RATIONALE:
// 1. Same arithmetic as the shared module: integer sums, one floating product
//    of the two variances before the square root, the same rounding of gray
//    and of a 2 x 2 box average, so a tolerance means the same on each OS.
// 2. Same search: power-of-two scales, a coarse pass at every pixel phase,
//    the strongest coarse candidates (score, then y, then x) refined at full
//    size, ties kept in row-major order.
// 3. Pinned by _shared/tests/corpus/keep_awake/auto_click_match_vectors.json,
//    which ScreenVisionMatcherTests replays.
// ==============================================================================

import Foundation

/// A grayscale image: row-major pixels 0 to 255, index 0 at the top-left corner.
struct ScreenVisionGray: Equatable {
	let width: Int
	let height: Int
	var pixels: [Int]
}

/// The matcher options, the keys of _shared/shortcuts/data/auto_click_defaults.json.
struct ScreenVisionMatchOptions {
	var threshold: Double
	var scales: [Double]
	var coarseMinPx: Int
	var coarseMargin: Double
	var coarseCandidates: Int
}

/// One match, its top-left corner in image pixels.
struct ScreenVisionHit: Equatable {
	let x: Int
	let y: Int
	let width: Int
	let height: Int
	let score: Double
	var scale: Double
}

enum ScreenVisionMatcher {

	// ======================================
	// ======= 1/ Images ====================
	// ======================================

	/// The luminance of one pixel, BT.601 weights rounded as the shared module.
	static func gray(_ r: Int, _ g: Int, _ b: Int) -> Int {
		return (r * 299 + g * 587 + b * 114 + 500) / 1000
	}

	/// Halves an image with a 2 x 2 box average at a phase of 0 or 1 pixel.
	static func halve(_ image: ScreenVisionGray, ox: Int = 0, oy: Int = 0) -> ScreenVisionGray? {
		let w = (image.width - ox) / 2
		let h = (image.height - oy) / 2
		guard w >= 1, h >= 1 else { return nil }
		let sw = image.width
		var out = [Int](repeating: 0, count: w * h)
		image.pixels.withUnsafeBufferPointer { src in
			for y in 0..<h {
				let rowA = (2 * y + oy) * sw + ox
				let rowB = rowA + sw
				for x in 0..<w {
					let c = 2 * x
					out[y * w + x] = (src[rowA + c] + src[rowA + c + 1] + src[rowB + c] + src[rowB + c + 1] + 2) / 4
				}
			}
		}
		return ScreenVisionGray(width: w, height: h, pixels: out)
	}

	/// Doubles an image by copying each pixel into a 2 x 2 block.
	static func double(_ image: ScreenVisionGray) -> ScreenVisionGray {
		let w = image.width * 2
		var out = [Int](repeating: 0, count: w * image.height * 2)
		for y in 0..<image.height {
			for x in 0..<image.width {
				let value = image.pixels[y * image.width + x]
				let top = 2 * y * w + 2 * x
				out[top] = value
				out[top + 1] = value
				out[top + w] = value
				out[top + w + 1] = value
			}
		}
		return ScreenVisionGray(width: w, height: image.height * 2, pixels: out)
	}

	/// Resizes by a power-of-two factor; nil for another factor or an image too small.
	static func scale(_ image: ScreenVisionGray, by factor: Double) -> ScreenVisionGray? {
		guard factor > 0 else { return nil }
		var out = image
		var f = factor
		while f > 1 {
			out = double(out)
			f /= 2
		}
		while f < 1 {
			guard let half = halve(out) else { return nil }
			out = half
			f *= 2
		}
		return f == 1 ? out : nil
	}

	// ======================================
	// ======= 2/ Correlation ===============
	// ======================================

	/// Summed-area tables of the pixels and their squares, a zero row and column first.
	struct Integrals {
		let stride: Int
		let sum: [Int]
		let squares: [Int]

		init(_ image: ScreenVisionGray) {
			let stride = image.width + 1
			var sum = [Int](repeating: 0, count: stride * (image.height + 1))
			var squares = sum
			for y in 1...image.height {
				var rowSum = 0
				var rowSquares = 0
				for x in 1...image.width {
					let v = image.pixels[(y - 1) * image.width + x - 1]
					rowSum += v
					rowSquares += v * v
					let at = y * stride + x
					sum[at] = sum[at - stride] + rowSum
					squares[at] = squares[at - stride] + rowSquares
				}
			}
			self.stride = stride
			self.sum = sum
			self.squares = squares
		}

		func window(_ table: [Int], _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> Int {
			let top = y * stride
			let bottom = (y + h) * stride
			return table[bottom + x + w] - table[top + x + w] - table[bottom + x] + table[top + x]
		}
	}

	/// What a template contributes to every score; nil for a flat template.
	struct Prepared {
		let image: ScreenVisionGray
		let n: Int
		let sum: Int
		let variance: Int

		init?(_ template: ScreenVisionGray) {
			let n = template.width * template.height
			var s = 0
			var ss = 0
			for v in template.pixels {
				s += v
				ss += v * v
			}
			let variance = n * ss - s * s
			guard variance > 0 else { return nil }
			self.image = template
			self.n = n
			self.sum = s
			self.variance = variance
		}
	}

	static func score(_ image: ScreenVisionGray, _ integrals: Integrals, _ prepared: Prepared, _ x: Int, _ y: Int) -> Double {
		let t = prepared.image
		var cross = 0
		image.pixels.withUnsafeBufferPointer { ip in
			t.pixels.withUnsafeBufferPointer { tp in
				for row in 0..<t.height {
					let baseI = (y + row) * image.width + x
					let baseT = row * t.width
					for col in 0..<t.width {
						cross += ip[baseI + col] * tp[baseT + col]
					}
				}
			}
		}
		let si = integrals.window(integrals.sum, x, y, t.width, t.height)
		let windowVariance = prepared.n * integrals.window(integrals.squares, x, y, t.width, t.height) - si * si
		if windowVariance <= 0 { return 0 }
		let numerator = Double(prepared.n * cross - si * prepared.sum)
		return numerator / (Double(windowVariance) * Double(prepared.variance)).squareRoot()
	}

	// ======================================
	// ======= 3/ Search ====================
	// ======================================

	private struct Candidate {
		let x: Int
		let y: Int
		let score: Double

		func ranksBefore(_ other: Candidate) -> Bool {
			if score != other.score { return score > other.score }
			if y != other.y { return y < other.y }
			return x < other.x
		}
	}

	private struct Variant {
		let image: ScreenVisionGray
		let ox: Int
		let oy: Int
	}

	private static func phaseVariants(_ image: ScreenVisionGray, levels: Int, minW: Int, minH: Int) -> [Variant] {
		if levels == 0 { return [Variant(image: image, ox: 0, oy: 0)] }
		var out: [Variant] = []
		for oy in 0...1 {
			for ox in 0...1 {
				guard (image.width - ox) / 2 >= minW, (image.height - oy) / 2 >= minH,
					let half = halve(image, ox: ox, oy: oy)
				else { continue }
				for v in phaseVariants(half, levels: levels - 1, minW: minW, minH: minH) {
					out.append(Variant(image: v.image, ox: ox + 2 * v.ox, oy: oy + 2 * v.oy))
				}
			}
		}
		return out
	}

	/// Whether a template can match at all: a flat image matches anywhere.
	static func isUniform(_ template: ScreenVisionGray) -> Bool {
		return Prepared(template) == nil
	}

	/// The best match of a template across scales, or nil; uniform is true when
	/// no scale could be scored because the template is flat.
	static func find(_ image: ScreenVisionGray, _ template: ScreenVisionGray,
		_ options: ScreenVisionMatchOptions) -> (hit: ScreenVisionHit?, uniform: Bool) {
		let integrals = Integrals(image)
		var variantsCache: [String: [Variant]] = [:]
		var best: ScreenVisionHit?
		var uniform = false
		for factor in options.scales {
			guard let scaled = scale(template, by: factor),
				scaled.width <= image.width, scaled.height <= image.height
			else { continue }
			guard let prepared = Prepared(scaled) else {
				uniform = true
				continue
			}
			if var hit = findAtScale(image, integrals, prepared, options, &variantsCache),
				best == nil || hit.score > best!.score {
				hit.scale = factor
				best = hit
			}
		}
		return (best, best == nil && uniform)
	}

	private static func findAtScale(_ image: ScreenVisionGray, _ integrals: Integrals, _ prepared: Prepared,
		_ options: ScreenVisionMatchOptions, _ cache: inout [String: [Variant]]) -> ScreenVisionHit? {
		let t = prepared.image
		var levels = 0
		var factor = 1
		var small = t
		while min(small.width, small.height) / 2 >= options.coarseMinPx, let half = halve(small) {
			small = half
			levels += 1
			factor *= 2
		}
		let maxX = image.width - t.width
		let maxY = image.height - t.height
		var boxes: [(Int, Int, Int, Int)] = []
		if levels == 0 {
			boxes.append((0, 0, maxX, maxY))
		} else {
			guard let coarse = Prepared(small) else { return nil }
			let key = "\(levels):\(small.width):\(small.height)"
			let variants = cache[key] ?? phaseVariants(image, levels: levels, minW: small.width, minH: small.height)
			cache[key] = variants
			let floor = options.threshold - options.coarseMargin
			var kept: [Candidate] = []
			for v in variants {
				let vi = Integrals(v.image)
				guard v.image.width >= small.width, v.image.height >= small.height else { continue }
				for y in 0...(v.image.height - small.height) {
					for x in 0...(v.image.width - small.width) {
						let s = score(v.image, vi, coarse, x, y)
						guard s >= floor else { continue }
						let candidate = Candidate(x: v.ox + x * factor, y: v.oy + y * factor, score: s)
						var index = kept.count
						while index > 0 && candidate.ranksBefore(kept[index - 1]) { index -= 1 }
						if index < options.coarseCandidates {
							kept.insert(candidate, at: index)
							if kept.count > options.coarseCandidates { kept.removeLast() }
						}
					}
				}
			}
			for c in kept { boxes.append((c.x - 1, c.y - 1, c.x + 1, c.y + 1)) }
		}
		var best: ScreenVisionHit?
		for (x0, y0, x1, y1) in boxes {
			let yStart = max(0, y0)
			let yEnd = min(maxY, y1)
			let xStart = max(0, x0)
			let xEnd = min(maxX, x1)
			guard yStart <= yEnd, xStart <= xEnd else { continue }
			for y in yStart...yEnd {
				for x in xStart...xEnd {
					let s = score(image, integrals, prepared, x, y)
					guard s >= options.threshold else { continue }
					if let current = best {
						let better = s > current.score
							|| (s == current.score && (y < current.y || (y == current.y && x < current.x)))
						if !better { continue }
					}
					best = ScreenVisionHit(x: x, y: y, width: t.width, height: t.height, score: s, scale: 1)
				}
			}
		}
		return best
	}
}
