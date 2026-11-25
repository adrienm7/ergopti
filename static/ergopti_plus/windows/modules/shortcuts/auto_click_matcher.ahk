; modules/shortcuts/auto_click_matcher.ahk

; ==============================================================================
; MODULE: Auto-Click Template Matcher (AutoHotkey port)
; DESCRIPTION:
; Port of _shared/shortcuts/engine/keep_awake/auto_click_matcher.lua, the matcher the
; macOS and Linux drivers share for the anti-sleep auto-clicker (Ctrl+M,
; sg_actions.activity_simulation): a library button image is searched for in a
; grayscale capture of the foreground window.
;
; FEATURES & RATIONALE:
; 1. Same algorithm and same arithmetic as the shared module: zero-mean
;    normalised cross-correlation from integer sums, a float only for the
;    product of the two variances, so a tolerance means the same on each OS.
;    AHK ImageSearch is not used: its *n variation counts colour shades per
;    pixel and has no mapping to a correlation tolerance.
; 2. Power-of-two scales (a box average halves, a pixel copy doubles), and a
;    coarse pass at every pixel phase, as in the shared module.
; 3. The coarse candidates are kept as a bounded best-first list rather than
;    fully sorted: the order (score, then y, then x) is total, so the kept
;    candidates are the ones the shared full sort keeps.
; 4. An image is an object { Width, Height, Pixels }, Pixels a row-major Array
;    of gray integers 0 to 255, index 1 at the top-left corner.
;
; Pinned by _shared/tests/corpus/keep_awake/auto_click_match_vectors.json,
; which tests/unit/modules/shortcuts/test_auto_click_matcher.ahk replays.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==============================
; ==============================
; ======= 1/ Images ============
; ==============================
; ==============================

; The luminance of one pixel (ITU-R BT.601 weights), rounded as the shared module.
; @returns {Integer} 0 to 255.
AutoClickGray(R, G, B) {
	return Floor((R * 299 + G * 587 + B * 114 + 500) / 1000)
}

; Rejects an image the shared module would refuse.
_AutoClickCheckImage(Image, What) {
	if !IsObject(Image) || !Image.HasOwnProp("Width") || !Image.HasOwnProp("Height") || !Image.HasOwnProp("Pixels")
		throw TypeError(What . " must be an image object.")
	if !IsInteger(Image.Width) || Image.Width < 1 || !IsInteger(Image.Height) || Image.Height < 1
		throw ValueError(What . " needs a positive integer width and height.")
	if !(Image.Pixels is Array) || Image.Pixels.Length != Image.Width * Image.Height
		throw ValueError(What . " needs width * height pixels.")
}

; Builds an image from rows of gray integers, top to bottom.
; @returns {Object} The image.
AutoClickFromRows(Rows) {
	if !(Rows is Array) || Rows.Length < 1
		throw ValueError("An image needs at least one row.")
	Width := Rows[1].Length
	Pixels := []
	for Row in Rows {
		if Row.Length != Width
			throw ValueError("Every row of an image has the same width.")
		for Value in Row
			Pixels.Push(Value)
	}
	return { Width: Width, Height: Rows.Length, Pixels: Pixels }
}

; Halves an image with a 2x2 box average at a phase of 0 or 1 pixel per axis.
; @returns {Object} The image.
AutoClickHalve(Image, Ox := 0, Oy := 0) {
	W := Floor((Image.Width - Ox) / 2)
	H := Floor((Image.Height - Oy) / 2)
	if W < 1 || H < 1
		throw ValueError("An image this small cannot be halved.")
	Sw := Image.Width, Src := Image.Pixels
	Pixels := []
	Pixels.Capacity := W * H
	Y := 0
	while Y < H {
		RowA := (2 * Y + Oy) * Sw + Ox
		RowB := RowA + Sw
		X := 0
		while X < W {
			C := 2 * X + 1
			Pixels.Push(Floor((Src[RowA + C] + Src[RowA + C + 1] + Src[RowB + C] + Src[RowB + C + 1] + 2) / 4))
			X += 1
		}
		Y += 1
	}
	return { Width: W, Height: H, Pixels: Pixels }
}

; Doubles an image by copying each pixel into a 2x2 block.
; @returns {Object} The image.
AutoClickDouble(Image) {
	Sw := Image.Width, Src := Image.Pixels
	Pixels := []
	Y := 0
	while Y < Image.Height {
		Row := []
		X := 0
		while X < Sw {
			Value := Src[Y * Sw + X + 1]
			Row.Push(Value, Value)
			X += 1
		}
		Pixels.Push(Row*)
		Pixels.Push(Row*)
		Y += 1
	}
	return { Width: Sw * 2, Height: Image.Height * 2, Pixels: Pixels }
}

; Resizes an image by a power-of-two factor.
; @returns {Object} The image.
AutoClickScale(Image, Factor) {
	if !IsNumber(Factor) || Factor <= 0
		throw ValueError("A scale factor must be a positive number.")
	Out := Image, F := Factor
	while F > 1 {
		Out := AutoClickDouble(Out)
		F := F / 2
	}
	while F < 1 {
		Out := AutoClickHalve(Out)
		F := F * 2
	}
	if F != 1
		throw ValueError("A scale factor must be a power of two.")
	return Out
}




; ===================================
; ===================================
; ======= 2/ Correlation ============
; ===================================
; ===================================

; Summed-area tables of the pixels and their squares, a zero row and column first.
_AutoClickIntegrals(Image, &Sum, &Sq) {
	W := Image.Width, H := Image.Height, Src := Image.Pixels
	Stride := W + 1
	Sum := [], Sq := []
	Sum.Capacity := Stride * (H + 1), Sq.Capacity := Stride * (H + 1)
	Loop Stride {
		Sum.Push(0), Sq.Push(0)
	}
	Y := 1
	while Y <= H {
		RowSum := 0, RowSq := 0
		Sum.Push(0), Sq.Push(0)
		X := 1
		while X <= W {
			V := Src[(Y - 1) * W + X]
			RowSum += V, RowSq += V * V
			At := Y * Stride + X + 1
			Sum.Push(Sum[At - Stride] + RowSum)
			Sq.Push(Sq[At - Stride] + RowSq)
			X += 1
		}
		Y += 1
	}
}

_AutoClickWindowSum(Table, Stride, X, Y, W, H) {
	Top := Y * Stride, Bottom := (Y + H) * Stride
	return Table[Bottom + X + W + 1] - Table[Top + X + W + 1] - Table[Bottom + X + 1] + Table[Top + X + 1]
}

; What a template contributes to every score; "" for a flat template.
_AutoClickPrepare(Template) {
	N := Template.Width * Template.Height, S := 0, Ss := 0
	for V in Template.Pixels
		S += V, Ss += V * V
	Variance := N * Ss - S * S
	if Variance <= 0
		return ""
	return { Image: Template, N: N, Sum: S, Variance: Variance }
}

_AutoClickScoreAt(Image, Sum, Sq, Stride, Prepared, X, Y) {
	Tpl := Prepared.Image
	Tw := Tpl.Width, Th := Tpl.Height, Tp := Tpl.Pixels, Ip := Image.Pixels, Iw := Image.Width
	Cross := 0
	Row := 0
	while Row < Th {
		BaseI := (Y + Row) * Iw + X
		BaseT := Row * Tw
		Col := 1
		while Col <= Tw {
			Cross += Ip[BaseI + Col] * Tp[BaseT + Col]
			Col += 1
		}
		Row += 1
	}
	N := Prepared.N
	Si := _AutoClickWindowSum(Sum, Stride, X, Y, Tw, Th)
	WindowVariance := N * _AutoClickWindowSum(Sq, Stride, X, Y, Tw, Th) - Si * Si
	if WindowVariance <= 0
		return 0
	return (N * Cross - Si * Prepared.Sum) / Sqrt((WindowVariance * 1.0) * Prepared.Variance)
}

; Whether candidate A ranks before B: higher score, then smaller y, then x.
_AutoClickRanksBefore(A, B) {
	if A.Score != B.Score
		return A.Score > B.Score
	if A.Y != B.Y
		return A.Y < B.Y
	return A.X < B.X
}

; Inserts a candidate into a best-first list bounded to Limit entries.
_AutoClickKeepBest(List, Candidate, Limit) {
	Index := List.Length + 1
	while Index > 1 && _AutoClickRanksBefore(Candidate, List[Index - 1])
		Index -= 1
	if Index > Limit
		return
	List.InsertAt(Index, Candidate)
	if List.Length > Limit
		List.Pop()
}

; Every halving of an image down Levels levels, one per pixel phase.
_AutoClickPhaseVariants(Image, Levels, MinW, MinH) {
	if Levels = 0
		return [{ Image: Image, Ox: 0, Oy: 0 }]
	Out := []
	for Oy in [0, 1] {
		for Ox in [0, 1] {
			if Floor((Image.Width - Ox) / 2) >= MinW && Floor((Image.Height - Oy) / 2) >= MinH {
				Half := AutoClickHalve(Image, Ox, Oy)
				for V in _AutoClickPhaseVariants(Half, Levels - 1, MinW, MinH)
					Out.Push({ Image: V.Image, Ox: Ox + 2 * V.Ox, Oy: Oy + 2 * V.Oy })
			}
		}
	}
	return Out
}




; ==================================
; ==================================
; ======= 3/ Public API ============
; ==================================
; ==================================

; Finds the best match of one template in an image, across scales.
; @param Options {Map} threshold, scales, coarse_min_px, coarse_margin and
;   coarse_candidates, as in _shared/shortcuts/data/auto_click_defaults.json.
; @param Reason {VarRef} Set to "template_uniform" when the template cannot match.
; @returns {Object|String} { X, Y, Width, Height, Score, Scale }, 0-based
;   top-left corner, or "" when no position reaches the threshold.
AutoClickFind(Image, Template, Options, &Reason := "") {
	_AutoClickCheckImage(Image, "The capture")
	_AutoClickCheckImage(Template, "The template")
	Threshold := Options["threshold"]
	if !IsNumber(Threshold) || Threshold <= 0 || Threshold > 1
		throw ValueError("The threshold is a number in ]0, 1].")
	if !(Options["scales"] is Array) || Options["scales"].Length < 1
		throw ValueError("The matcher needs at least one scale.")
	if Options["coarse_min_px"] < 2 || Options["coarse_margin"] < 0 || Options["coarse_candidates"] < 1
		throw ValueError("The coarse search options are out of range.")
	Reason := ""
	Cache := { Variants: Map(), Sum: "", Sq: "" }
	Best := "", Uniform := false
	for Factor in Options["scales"] {
		try Scaled := AutoClickScale(Template, Factor)
		catch
			continue
		if Scaled.Width > Image.Width || Scaled.Height > Image.Height
			continue
		Prepared := _AutoClickPrepare(Scaled)
		if !IsObject(Prepared) {
			Uniform := true
			continue
		}
		Match := AutoClickFindAtScale(Image, Prepared, Threshold, Options, Cache)
		if IsObject(Match) && (!IsObject(Best) || Match.Score > Best.Score) {
			Match.Scale := Factor
			Best := Match
		}
	}
	if !IsObject(Best) && Uniform
		Reason := "template_uniform"
	return Best
}

; Coarse-to-fine search of one prepared template at its own size.
; @returns {Object|String} The match or "".
AutoClickFindAtScale(Image, Prepared, Threshold, Options, Cache) {
	Tpl := Prepared.Image
	Tw := Tpl.Width, Th := Tpl.Height
	Levels := 0, Factor := 1, Small := Tpl
	while Floor(Min(Small.Width, Small.Height) / 2) >= Options["coarse_min_px"] {
		Small := AutoClickHalve(Small)
		Levels += 1, Factor *= 2
	}
	MaxX := Image.Width - Tw, MaxY := Image.Height - Th
	Candidates := []
	if Levels = 0 {
		Candidates.Push({ X0: 0, Y0: 0, X1: MaxX, Y1: MaxY })
	} else {
		CoarsePrepared := _AutoClickPrepare(Small)
		if !IsObject(CoarsePrepared)
			return ""
		Key := Levels . ":" . Small.Width . ":" . Small.Height
		if !Cache.Variants.Has(Key)
			Cache.Variants[Key] := _AutoClickPhaseVariants(Image, Levels, Small.Width, Small.Height)
		Floor_ := Threshold - Options["coarse_margin"]
		Found := []
		for V in Cache.Variants[Key] {
			_AutoClickIntegrals(V.Image, &VSum, &VSq)
			VStride := V.Image.Width + 1
			Y := 0
			while Y <= V.Image.Height - Small.Height {
				X := 0
				while X <= V.Image.Width - Small.Width {
					Score := _AutoClickScoreAt(V.Image, VSum, VSq, VStride, CoarsePrepared, X, Y)
					if Score >= Floor_
						_AutoClickKeepBest(Found, { X: V.Ox + X * Factor, Y: V.Oy + Y * Factor, Score: Score },
							Options["coarse_candidates"])
					X += 1
				}
				Y += 1
			}
		}
		for C in Found
			Candidates.Push({ X0: C.X - 1, Y0: C.Y - 1, X1: C.X + 1, Y1: C.Y + 1 })
	}

	if !IsObject(Cache.Sum) {
		_AutoClickIntegrals(Image, &FullSum, &FullSq)
		Cache.Sum := FullSum, Cache.Sq := FullSq
	}
	Stride := Image.Width + 1
	Best := ""
	for C in Candidates {
		Y := Max(0, C.Y0)
		while Y <= Min(MaxY, C.Y1) {
			X := Max(0, C.X0)
			while X <= Min(MaxX, C.X1) {
				Score := _AutoClickScoreAt(Image, Cache.Sum, Cache.Sq, Stride, Prepared, X, Y)
				if Score >= Threshold && (!IsObject(Best) || Score > Best.Score
					|| (Score = Best.Score && (Y < Best.Y || (Y = Best.Y && X < Best.X))))
					Best := { X: X, Y: Y, Width: Tw, Height: Th, Score: Score }
				X += 1
			}
			Y += 1
		}
	}
	return Best
}

; Validates a library image at import: refuses a flat template.
; @returns {String} "" when it can match, else "template_uniform".
AutoClickCheckTemplate(Template) {
	_AutoClickCheckImage(Template, "The template")
	return IsObject(_AutoClickPrepare(Template)) ? "" : "template_uniform"
}

; The screen point a match is clicked at, its centre in screen pixels.
; @param FrameX {Integer} Left of the captured window on screen.
; @param FrameY {Integer} Top of the captured window on screen.
; @param CaptureScale {Number} Capture pixels per screen unit (1 for a GDI capture).
AutoClickClickPoint(FrameX, FrameY, CaptureScale, Match, &X, &Y) {
	if !IsNumber(CaptureScale) || CaptureScale <= 0
		throw ValueError("The capture scale is a positive number.")
	X := Floor(FrameX + (Match.X + Match.Width / 2) / CaptureScale)
	Y := Floor(FrameY + (Match.Y + Match.Height / 2) / CaptureScale)
}
