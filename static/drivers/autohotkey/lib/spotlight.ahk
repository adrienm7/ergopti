; drivers/autohotkey/lib/spotlight.ahk

; ==============================================================================
; MODULE: Spotlight Overlay
; DESCRIPTION:
; GDI+ layered-window overlay that highlights the mouse cursor position:
; a filled yellow circle on the cursor's monitor and a red cross on every
; other monitor. Dismissed after a configured timeout or as soon as the mouse
; moves more than 5 pixels from the trigger point.
;
; FEATURES & RATIONALE:
; 1. GDI+ via DllCall: AHK v2 ships no graphics library; the GDI+ COM layer is
;    loaded per-call and shut down immediately after the windows are destroyed
;    so no global state leaks between invocations.
; 2. Per-pixel alpha: UpdateLayeredWindow with AC_SRC_ALPHA renders the
;    semi-transparent fill and stroke without a rectangular bounding box.
; 3. Extracted here from modules/shortcuts/win.ahk so the rendering logic is
;    testable and shareable without loading any hotkey-registration code.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =====================================
; ======= 1/ Spotlight renderer =======
; =====================================
; =======================================

; Draws a filled yellow circle around (X, Y) and a red cross on every other
; monitor, matching the Hammerspoon spotlight visual exactly.
; Dismissed after DurationMs ms or as soon as the mouse moves more than 5 px.
SpotlightMouseAt(X, Y, DurationMs) {
	static RING_RADIUS    := 60     ; Matches Hammerspoon SPOTLIGHT_RADIUS_PX
	static RING_STROKE    := 6      ; Matches SPOTLIGHT_STROKE_PX
	static FILL_ALPHA     := 102    ; 0.40 x 255 -- matches SPOTLIGHT_FILL_ALPHA
	static STROKE_ALPHA   := 230    ; 0.90 x 255 -- matches OVERLAY_STROKE_ALPHA
	static PAD            := 12     ; Matches SPOTLIGHT_PADDING_PX
	static CROSS_HALF     := 60     ; Matches CROSS_ARM_HALF_PX
	static CROSS_WIDTH    := 14     ; Matches CROSS_ARM_WIDTH_PX
	static DISMISS_POLL   := 100

	; ARGB values (pre-multiplied alpha not needed for UpdateLayeredWindow with AC_SRC_ALPHA)
	static YELLOW_FILL    := 0x66FFDA00   ; alpha=0x66(102), R=255, G=218, B=0
	static YELLOW_STROKE  := 0xE6FFDA00   ; alpha=0xE6(230)
	static RED_FILL       := 0x66E61A0D   ; alpha=0x66, R=230, G=26, B=13
	static RED_STROKE     := 0xE6E61A0D   ; alpha=0xE6

	; GDI+ startup -- shared token for all windows drawn this call
	DllCall("LoadLibrary", "str", "gdiplus")
	si := Buffer(24, 0)
	NumPut("uint", 1, si)
	DllCall("gdiplus\GdiplusStartup", "ptr*", &pToken := 0, "ptr", si, "ptr", 0)

	; --- Helper: create a layered window, paint via GDI+ callback, return hwnd ---
	CreateOverlayWindow(WinX, WinY, WinW, WinH, DrawCallback) {
		; WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW
		Hwnd := DllCall("CreateWindowEx",
			"uint",  0x8009C,
			"str",   "Static", "str", "",
			"uint",  0x80000000,   ; WS_POPUP
			"int",   WinX, "int", WinY, "int", WinW, "int", WinH,
			"ptr",   0, "ptr", 0, "ptr", 0, "ptr", 0,
			"ptr")
		if not Hwnd
			return 0

		hScreenDC := DllCall("GetDC", "ptr", 0, "ptr")
		hMemDC    := DllCall("CreateCompatibleDC", "ptr", hScreenDC, "ptr")

		; 32-bpp DIB section -- required for per-pixel alpha in UpdateLayeredWindow
		bi := Buffer(40, 0)
		NumPut("int",   40,    bi,  0)   ; biSize
		NumPut("int",   WinW,  bi,  4)   ; biWidth
		NumPut("int",  -WinH,  bi,  8)   ; biHeight (negative = top-down)
		NumPut("short", 1,     bi, 12)   ; biPlanes
		NumPut("short", 32,    bi, 14)   ; biBitCount
		hBitmap := DllCall("CreateDIBSection", "ptr", hMemDC, "ptr", bi, "uint", 0, "ptr*", 0, "ptr", 0, "uint", 0, "ptr")
		DllCall("SelectObject", "ptr", hMemDC, "ptr", hBitmap)

		; GDI+ Graphics on the memory DC
		DllCall("gdiplus\GdipCreateFromHDC", "ptr", hMemDC, "ptr*", &pGfx := 0)
		DllCall("gdiplus\GdipSetSmoothingMode",    "ptr", pGfx, "int", 4)   ; AntiAlias
		DllCall("gdiplus\GdipSetCompositingMode",  "ptr", pGfx, "int", 0)   ; SourceOver
		DllCall("gdiplus\GdipSetCompositingQuality","ptr", pGfx, "int", 0)  ; Default

		DrawCallback(pGfx, WinW, WinH)

		DllCall("gdiplus\GdipDeleteGraphics", "ptr", pGfx)

		; Commit the bitmap to the layered window
		ptDst  := Buffer(8, 0)
		NumPut("int", WinX, ptDst, 0), NumPut("int", WinY, ptDst, 4)
		szWin  := Buffer(8, 0)
		NumPut("int", WinW, szWin, 0), NumPut("int", WinH, szWin, 4)
		ptSrc  := Buffer(8, 0)
		blend  := Buffer(4, 0)
		NumPut("uchar", 0,   blend, 0)   ; BlendOp = AC_SRC_OVER
		NumPut("uchar", 0,   blend, 1)   ; BlendFlags
		NumPut("uchar", 255, blend, 2)   ; SourceConstantAlpha (per-pixel drives it)
		NumPut("uchar", 1,   blend, 3)   ; AlphaFormat = AC_SRC_ALPHA

		DllCall("UpdateLayeredWindow",
			"ptr",  Hwnd,
			"ptr",  hScreenDC,
			"ptr",  ptDst,
			"ptr",  szWin,
			"ptr",  hMemDC,
			"ptr",  ptSrc,
			"uint", 0,
			"ptr",  blend,
			"uint", 2)          ; ULW_ALPHA

		DllCall("ShowWindow", "ptr", Hwnd, "int", 4)   ; SW_SHOWNOACTIVATE

		DllCall("DeleteObject", "ptr", hBitmap)
		DllCall("DeleteDC",     "ptr", hMemDC)
		DllCall("ReleaseDC",    "ptr", 0, "ptr", hScreenDC)

		return Hwnd
	}

	; --- Draw the yellow filled circle on the cursor's screen ---
	Size   := (RING_RADIUS + PAD) * 2
	WinX   := X - RING_RADIUS - PAD
	WinY   := Y - RING_RADIUS - PAD

	CircleDraw(pGfx, W, H) {
		; Filled ellipse
		DllCall("gdiplus\GdipCreateSolidFill", "uint", YELLOW_FILL, "ptr*", &pBrush := 0)
		DllCall("gdiplus\GdipFillEllipse",
			"ptr", pGfx, "ptr", pBrush,
			"float", PAD, "float", PAD,
			"float", RING_RADIUS * 2, "float", RING_RADIUS * 2)
		DllCall("gdiplus\GdipDeleteBrush", "ptr", pBrush)

		; Stroke ellipse
		DllCall("gdiplus\GdipCreatePen1", "uint", YELLOW_STROKE, "float", RING_STROKE, "int", 2, "ptr*", &pPen := 0)
		DllCall("gdiplus\GdipDrawEllipse",
			"ptr", pGfx, "ptr", pPen,
			"float", PAD + RING_STROKE / 2, "float", PAD + RING_STROKE / 2,
			"float", RING_RADIUS * 2 - RING_STROKE, "float", RING_RADIUS * 2 - RING_STROKE)
		DllCall("gdiplus\GdipDeletePen", "ptr", pPen)
	}

	CircleHwnd := CreateOverlayWindow(WinX, WinY, Size, Size, CircleDraw)

	; --- Draw a red cross centered on every OTHER monitor ---
	CrossSize := (CROSS_HALF + PAD) * 2
	CrossHwnds := []

	MonCount := MonitorGetCount()
	loop MonCount {
		MonitorGet(A_Index, &ML, &MT, &MR, &MB)
		; Skip the monitor that holds the cursor
		if (X >= ML and X < MR and Y >= MT and Y < MB)
			continue

		CX := ML + (MR - ML) // 2
		CY := MT + (MB - MT) // 2

		CWinX := CX - CROSS_HALF - PAD
		CWinY := CY - CROSS_HALF - PAD

		CrossDraw(pGfx, W, H) {
			HW := CROSS_WIDTH / 2

			; Horizontal bar
			DllCall("gdiplus\GdipCreateSolidFill", "uint", RED_FILL, "ptr*", &pBrush := 0)
			DllCall("gdiplus\GdipFillRectangle",
				"ptr", pGfx, "ptr", pBrush,
				"float", PAD, "float", PAD + CROSS_HALF - HW,
				"float", CROSS_HALF * 2, "float", CROSS_WIDTH)
			; Vertical bar
			DllCall("gdiplus\GdipFillRectangle",
				"ptr", pGfx, "ptr", pBrush,
				"float", PAD + CROSS_HALF - HW, "float", PAD,
				"float", CROSS_WIDTH, "float", CROSS_HALF * 2)
			DllCall("gdiplus\GdipDeleteBrush", "ptr", pBrush)

			; Strokes
			DllCall("gdiplus\GdipCreatePen1", "uint", RED_STROKE, "float", RING_STROKE, "int", 2, "ptr*", &pPen := 0)
			DllCall("gdiplus\GdipDrawRectangle",
				"ptr", pGfx, "ptr", pPen,
				"float", PAD + RING_STROKE / 2, "float", PAD + CROSS_HALF - HW + RING_STROKE / 2,
				"float", CROSS_HALF * 2 - RING_STROKE, "float", CROSS_WIDTH - RING_STROKE)
			DllCall("gdiplus\GdipDrawRectangle",
				"ptr", pGfx, "ptr", pPen,
				"float", PAD + CROSS_HALF - HW + RING_STROKE / 2, "float", PAD + RING_STROKE / 2,
				"float", CROSS_WIDTH - RING_STROKE, "float", CROSS_HALF * 2 - RING_STROKE)
			DllCall("gdiplus\GdipDeletePen", "ptr", pPen)
		}

		CrossHwnds.Push(CreateOverlayWindow(CWinX, CWinY, CrossSize, CrossSize, CrossDraw))
	}

	; --- Poll for mouse move or timeout, then destroy all windows ---
	StartX := X, StartY := Y
	Elapsed := 0
	loop {
		Sleep(DISMISS_POLL)
		Elapsed += DISMISS_POLL
		MouseGetPos(&NowX, &NowY)
		if (Elapsed >= DurationMs or Abs(NowX - StartX) > 5 or Abs(NowY - StartY) > 5)
			break
	}

	if CircleHwnd
		DllCall("DestroyWindow", "ptr", CircleHwnd)
	for Hwnd in CrossHwnds
		DllCall("DestroyWindow", "ptr", Hwnd)

	DllCall("gdiplus\GdiplusShutdown", "ptr", pToken)
}
