; tests/unit/test_tooltip_border_alpha.ahk

; ==============================================================================
; MODULE: Tooltip Border Alpha-Fixup Tests
; DESCRIPTION:
; Pins the correctness of _TooltipFixBorderAlpha (infra/tooltip.ahk), the optimized
; per-pixel pass that rewrites GDI RoundRect output to premultiplied border alpha
; for the layered border window. The production scan only visits the two
; horizontal edge rows, the corner-column zones of the top/bottom bands, and the
; vertical edge columns of the middle rows -- a deliberate departure from a naive
; full-bitmap scan, taken because the BorderPixelLoop hot-path warnings clustered
; on short 1-2 row preview tooltips where the corner band spans nearly the whole
; height.
;
; RATIONALE:
; The optimization is only safe if the visited zones cover EXACTLY the pixels GDI
; actually paints. Rather than trust geometric reasoning, each test paints a real
; GDI RoundRect into a 32-bpp DIB (mirroring _TooltipShowBorder), runs the
; production fixup on one copy and a full O(Wp*Hp) reference scan on a second
; identical copy, and asserts the two buffers are byte-identical. Any pixel GDI
; paints outside the optimized scan's zones -- for any geometry, present or future
; -- makes the buffers diverge and fails the test. This is the root-cause guard:
; the invariant is "optimized scan == rewrite-every-nonzero-pixel", verified
; against the real rasterizer, not a model of it.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =====================================================
; ======= 1/ GDI RoundRect DIB Painting Helpers =======
; =====================================================
; =====================================================

; Paint a 1 px white rounded-rect outline into a fresh top-down 32-bpp DIB,
; mirroring the DIB build in _TooltipShowBorder so the test exercises the exact
; pixel layout the production rasterizer produces. Returns a record carrying the
; handles (for cleanup) and the base pixel pointer. Caller must call _TtbFreeDib.
_TtbPaintRoundRect(Wp, Hp, Diam) {
	BmpInfo := Buffer(40, 0)
	NumPut("UInt", 40, BmpInfo, 0)    ; biSize
	NumPut("Int", Wp, BmpInfo, 4)     ; biWidth
	NumPut("Int", -Hp, BmpInfo, 8)    ; biHeight (negative = top-down)
	NumPut("UShort", 1, BmpInfo, 12)  ; biPlanes
	NumPut("UShort", 32, BmpInfo, 14) ; biBitCount
	NumPut("UInt", 0, BmpInfo, 16)    ; biCompression = BI_RGB

	ScreenDC := DllCall("User32\GetDC", "Ptr", 0, "Ptr")
	PixPtr := 0
	HBmp := DllCall("Gdi32\CreateDIBSection",
		"Ptr", ScreenDC, "Ptr", BmpInfo, "UInt", 0,
		"Ptr*", &PixPtr, "Ptr", 0, "UInt", 0, "Ptr")
	MemDC := DllCall("Gdi32\CreateCompatibleDC", "Ptr", ScreenDC, "Ptr")
	DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", ScreenDC)
	OldBmp := DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", HBmp, "Ptr")

	; Clear to transparent black, then stroke the rounded-rect outline with a
	; 1 px white pen and a null brush -- identical to the production border build.
	DllCall("Gdi32\PatBlt", "Ptr", MemDC,
		"Int", 0, "Int", 0, "Int", Wp, "Int", Hp, "UInt", 0x42)  ; BLACKNESS
	HPen := DllCall("Gdi32\CreatePen", "Int", 0, "Int", 1, "UInt", 0xFFFFFF, "Ptr")
	HNull := DllCall("Gdi32\GetStockObject", "Int", 5, "Ptr")   ; NULL_BRUSH = 5
	OldPen := DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", HPen, "Ptr")
	OldBr := DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", HNull, "Ptr")
	DllCall("Gdi32\RoundRect",
		"Ptr", MemDC, "Int", 0, "Int", 0, "Int", Wp, "Int", Hp,
		"Int", Diam, "Int", Diam)
	DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", OldPen)
	DllCall("Gdi32\SelectObject", "Ptr", MemDC, "Ptr", OldBr)
	DllCall("Gdi32\DeleteObject", "Ptr", HPen)

	return { HBmp: HBmp, MemDC: MemDC, OldBmp: OldBmp, PixPtr: PixPtr }
}

; Release the GDI objects backing a DIB returned by _TtbPaintRoundRect.
_TtbFreeDib(D) {
	DllCall("Gdi32\SelectObject", "Ptr", D.MemDC, "Ptr", D.OldBmp)
	DllCall("Gdi32\DeleteDC", "Ptr", D.MemDC)
	DllCall("Gdi32\DeleteObject", "Ptr", D.HBmp)
}





; ===========================================================
; ===========================================================
; ======= 2/ Reference Scan and Comparison Primitives =======
; ===========================================================
; ===========================================================

; Authoritative reference fixup: rewrite EVERY non-zero pixel to PremulPx. This is
; the semantic the optimized _TooltipFixBorderAlpha must preserve exactly.
_TtbRefFixAlpha(PixPtr, Wp, Hp, PremulPx) {
	loop (Wp * Hp) {
		Off := (A_Index - 1) * 4
		if (NumGet(PixPtr, Off, "UInt") != 0)
			NumPut("UInt", PremulPx, PixPtr, Off)
	}
}

; Count non-zero pixels (sanity that RoundRect actually painted an outline).
_TtbCountNonZero(PixPtr, Wp, Hp) {
	N := 0
	loop (Wp * Hp) {
		if (NumGet(PixPtr, (A_Index - 1) * 4, "UInt") != 0)
			N += 1
	}
	return N
}

; Byte-for-byte equality over the full pixel area of two DIBs.
_TtbBuffersEqual(PtrA, PtrB, Wp, Hp) {
	loop (Wp * Hp) {
		Off := (A_Index - 1) * 4
		if (NumGet(PtrA, Off, "UInt") != NumGet(PtrB, Off, "UInt"))
			return false
	}
	return true
}




; ======================================
; ======================================
; ======= 3/ Test Registration =========
; ======================================
; ======================================

_RunTooltipBorderAlphaTests() {
	; Fixed premultiplied value (alpha = 0x40 = 25 %), independent of UI globals so
	; the test is deterministic regardless of the loaded theme.
	PremulPx := (0x40 << 24) | (0x40 << 16) | (0x40 << 8) | 0x40

	Cases := []
	; short_wide_preview: the common 1-row hotstring preview -- the band spans
	; nearly the whole height, the case the optimization targets.
	Cases.Push({ Id: "short_wide_preview", Wp: 200, Hp: 30,  Diam: 14 })
	Cases.Push({ Id: "tall_multirow",      Wp: 150, Hp: 120, Diam: 14 })
	Cases.Push({ Id: "narrow_square",      Wp: 20,  Hp: 20,  Diam: 14 })
	Cases.Push({ Id: "tiny_clamped",       Wp: 6,   Hp: 6,   Diam: 14 })
	Cases.Push({ Id: "square_corners",     Wp: 80,  Hp: 24,  Diam: 0 })
	Cases.Push({ Id: "diam_equals_dims",   Wp: 14,  Hp: 14,  Diam: 14 })

	for C in Cases {
		_RunOne(Cid, Cw, Ch, Cd, Premul) {
			Opt := _TtbPaintRoundRect(Cw, Ch, Cd)
			Ref := _TtbPaintRoundRect(Cw, Ch, Cd)
			Assert(Opt.PixPtr and Ref.PixPtr,
				"border alpha [" . Cid . "]: DIB creation failed")

			; RoundRect must have painted something, otherwise the byte-equality
			; check below would trivially pass on two all-zero buffers.
			Painted := _TtbCountNonZero(Opt.PixPtr, Cw, Ch)
			Assert(Painted > 0,
				"border alpha [" . Cid . "]: RoundRect painted no pixels")

			_TooltipFixBorderAlpha(Opt.PixPtr, Cw, Ch, Cd, Premul)
			_TtbRefFixAlpha(Ref.PixPtr, Cw, Ch, Premul)

			Assert(_TtbBuffersEqual(Opt.PixPtr, Ref.PixPtr, Cw, Ch),
				"border alpha [" . Cid . "]: optimized scan diverged from full-scan reference")

			; The same set of pixels must be non-zero after the fixup -- every
			; painted pixel is now PremulPx (non-zero), none were missed or zeroed.
			Assert(_TtbCountNonZero(Opt.PixPtr, Cw, Ch) == Painted,
				"border alpha [" . Cid . "]: painted-pixel count changed after fixup")

			_TtbFreeDib(Opt)
			_TtbFreeDib(Ref)
		}
		Test("tooltip border alpha: " . C.Id,
			_RunOne.Bind(C.Id, C.Wp, C.Hp, C.Diam, PremulPx))
	}
}

_RunTooltipBorderAlphaTests()
