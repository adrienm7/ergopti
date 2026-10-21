; adapters/screen_capture.ahk

; ==============================================================================
; MODULE: Screen Capture Adapter
; DESCRIPTION:
; Holds the GDI and GDI+ calls of the screenshot actions at the native
; boundary: a screen rectangle copied into a private DIB section, the admitted
; clipboard bitmap copied under its own lock, and the shrink-and-encode step
; that writes a private stage file. The gesture screenshot owner
; (modules/gestures/screenshots.ahk) keeps the workers, epochs, publication and
; cleanup; these functions only turn pixels into a stage file, or throw.
;
; FEATURES & RATIONALE:
; 1. In process - no script host or child process is started: a hidden process
;    compiling clipboard P/Invoke code is the shape of a stealer stage, and
;    corporate antivirus engines flagged the release that carried one.
; 2. Owned handles - every DC, bitmap, GDI+ image and startup token is released
;    in a finally block, on success and on failure alike.
; 3. One encoder path - direct and region captures share the same write, so the
;    longest-edge limit and the encoder choice behave identically for both.
; ==============================================================================

#Requires AutoHotkey v2.0

global GESTURE_SCREENSHOT_PIXEL_FORMAT_32BPP_ARGB := 0x26200A
global GESTURE_SCREENSHOT_INTERPOLATION_HIGH_QUALITY_BICUBIC := 7
global GESTURE_SCREENSHOT_SRCCOPY := 0x00CC0020
global GESTURE_SCREENSHOT_CF_BITMAP := 2
global GESTURE_SCREENSHOT_IMAGE_BITMAP := 0





; =============================================
; =============================================
; ======= 1/ GDI+ lifetime and encoding =======
; =============================================
; =============================================

_GestureScreenshotGdipCheck(Status, Operation) {
	if Status != 0
		throw Error(Operation . " failed with GDI+ status " . Status . ".")
}

; Runs Work between a GDI+ startup and its shutdown. GDI+ counts its startups,
; so this owner never disturbs the overlays which hold their own token.
; @param {Func} Work Called without arguments; its result is returned.
_GestureScreenshotWithGdiplus(Work) {
	Module := DllCall("Kernel32\LoadLibraryW", "Str", "gdiplus.dll", "Ptr")
	if !Module
		throw OSError(A_LastError, -1, "gdiplus.dll could not be loaded")
	try {
		Token := 0
		StartupInput := Buffer(24, 0)
		NumPut("UInt", 1, StartupInput)
		_GestureScreenshotGdipCheck(DllCall("gdiplus\GdiplusStartup", "Ptr*", &Token,
			"Ptr", StartupInput, "Ptr", 0, "Int"), "GdiplusStartup")
		try return Work.Call()
		finally DllCall("gdiplus\GdiplusShutdown", "Ptr", Token)
	} finally {
		DllCall("Kernel32\FreeLibrary", "Ptr", Module)
	}
}

; GDI+ copies the pixels, so the caller may delete the GDI bitmap at once.
; The bitmap must not be selected into a device context.
; @returns {Integer} The GDI+ bitmap, which the caller disposes.
_GestureScreenshotGdipFromHBitmap(HBitmap) {
	Image := 0
	_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipCreateBitmapFromHBITMAP",
		"Ptr", HBitmap, "Ptr", 0, "Ptr*", &Image, "Int"), "GdipCreateBitmapFromHBITMAP")
	return Image
}

_GestureScreenshotGdipDispose(Image) {
	if Image
		DllCall("gdiplus\GdipDisposeImage", "Ptr", Image)
}

; Shrinks Image so its longest edge is at most MaxEdge with high-quality
; bicubic resampling, then saves it. Image is replaced by the shrunk copy and
; stays owned by the caller, who disposes it whatever happens.
; @param {Integer} Image The GDI+ image, by reference.
; @param {String} Stage The private file to write.
; @param {String} Encoder The encoder CLSID (PNG or BMP).
; @param {Integer} MaxEdge The longest edge allowed, 0 to keep the size.
_GestureScreenshotGdipWrite(&Image, Stage, Encoder, MaxEdge) {
	global GESTURE_SCREENSHOT_PIXEL_FORMAT_32BPP_ARGB
	global GESTURE_SCREENSHOT_INTERPOLATION_HIGH_QUALITY_BICUBIC
	_GestureScreenshotRequireMaxEdge(MaxEdge)
	if MaxEdge {
		Width := 0, Height := 0
		_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipGetImageWidth", "Ptr", Image,
			"UInt*", &Width, "Int"), "GdipGetImageWidth")
		_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipGetImageHeight", "Ptr", Image,
			"UInt*", &Height, "Int"), "GdipGetImageHeight")
		Longest := Max(Width, Height)
		if Longest > MaxEdge {
			Scale := MaxEdge / Longest
			ScaledWidth := Max(1, Round(Width * Scale))
			ScaledHeight := Max(1, Round(Height * Scale))
			Scaled := 0
			_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipCreateBitmapFromScan0",
				"Int", ScaledWidth, "Int", ScaledHeight, "Int", 0,
				"Int", GESTURE_SCREENSHOT_PIXEL_FORMAT_32BPP_ARGB, "Ptr", 0, "Ptr*", &Scaled, "Int"),
				"GdipCreateBitmapFromScan0")
			try {
				Graphics := 0
				_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipGetImageGraphicsContext",
					"Ptr", Scaled, "Ptr*", &Graphics, "Int"), "GdipGetImageGraphicsContext")
				try {
					_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipSetInterpolationMode",
						"Ptr", Graphics, "Int", GESTURE_SCREENSHOT_INTERPOLATION_HIGH_QUALITY_BICUBIC,
						"Int"), "GdipSetInterpolationMode")
					_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipDrawImageRectI",
						"Ptr", Graphics, "Ptr", Image, "Int", 0, "Int", 0,
						"Int", ScaledWidth, "Int", ScaledHeight, "Int"), "GdipDrawImageRectI")
				} finally {
					if Graphics
						DllCall("gdiplus\GdipDeleteGraphics", "Ptr", Graphics)
				}
			} catch as Err {
				_GestureScreenshotGdipDispose(Scaled)
				throw Err
			}
			_GestureScreenshotGdipDispose(Image)
			Image := Scaled
		}
	}
	Clsid := Buffer(16, 0)
	HResult := DllCall("Ole32\CLSIDFromString", "WStr", Encoder, "Ptr", Clsid, "Int")
	if HResult != 0
		throw Error("The screenshot encoder CLSID is invalid (HRESULT " . HResult . ").")
	_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipSaveImageToFile", "Ptr", Image,
		"WStr", Stage, "Ptr", Clsid, "Ptr", 0, "Int"), "GdipSaveImageToFile")
}

_GestureScreenshotCaptureScreenGdip(X, Y, W, H, Encoder, Stage, MaxEdge) {
	global GESTURE_SCREENSHOT_SRCCOPY
	Image := 0
	ScreenDC := DllCall("User32\GetDC", "Ptr", 0, "Ptr")
	if !ScreenDC
		throw Error("The screen device context could not be acquired.")
	try {
		MemoryDC := DllCall("Gdi32\CreateCompatibleDC", "Ptr", ScreenDC, "Ptr")
		if !MemoryDC
			throw Error("The capture device context could not be created.")
		try {
			; A top-down 32-bit BITMAPINFOHEADER: biSize, biWidth, -biHeight,
			; biPlanes, biBitCount; BI_RGB compression stays zero.
			Header := Buffer(40, 0)
			NumPut("UInt", 40, "Int", W, "Int", -H, "UShort", 1, "UShort", 32, Header)
			Bits := 0
			Section := DllCall("Gdi32\CreateDIBSection", "Ptr", MemoryDC, "Ptr", Header,
				"UInt", 0, "Ptr*", &Bits, "Ptr", 0, "UInt", 0, "Ptr")
			if !Section
				throw Error("The capture bitmap could not be allocated.")
			try {
				Previous := DllCall("Gdi32\SelectObject", "Ptr", MemoryDC, "Ptr", Section, "Ptr")
				if !Previous
					throw Error("The capture bitmap could not be selected.")
				try {
					if !DllCall("Gdi32\BitBlt", "Ptr", MemoryDC, "Int", 0, "Int", 0, "Int", W, "Int", H,
							"Ptr", ScreenDC, "Int", X, "Int", Y, "UInt", GESTURE_SCREENSHOT_SRCCOPY, "Int")
						throw Error("The screen pixels could not be copied.")
				} finally {
					DllCall("Gdi32\SelectObject", "Ptr", MemoryDC, "Ptr", Previous, "Ptr")
				}
				Image := _GestureScreenshotGdipFromHBitmap(Section)
			} finally {
				DllCall("Gdi32\DeleteObject", "Ptr", Section)
			}
		} finally {
			DllCall("Gdi32\DeleteDC", "Ptr", MemoryDC)
		}
	} finally {
		DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", ScreenDC)
	}
	try _GestureScreenshotGdipWrite(&Image, Stage, Encoder, MaxEdge)
	finally _GestureScreenshotGdipDispose(Image)
}

; Delayed rendering may legitimately change the sequence during acquisition.
; Hold the native clipboard lock from admission through the detached GDI+ copy,
; then let later copies proceed independently of this captured image.
_GestureScreenshotCaptureClipboardImage(Stage, ExpectedSequence, MaxEdge) {
	global GESTURE_SCREENSHOT_CF_BITMAP, GESTURE_SCREENSHOT_IMAGE_BITMAP
	global GESTURE_SCREENSHOT_PNG_ENCODER
	Image := 0
	; The region image was just copied, which is when clipboard readers hold it.
	if !CB_OpenClipboardWithin(A_ScriptHwnd, _GestureScreenshotNativeProbe.Bind("contended", 0))
		throw Error("The region clipboard is busy.")
	try {
		if ExpectedSequence == 0
				|| DllCall("User32\GetClipboardSequenceNumber", "UInt") != ExpectedSequence
			throw Error("Region clipboard content changed before image acquisition.")
		Borrowed := DllCall("User32\GetClipboardData", "UInt", GESTURE_SCREENSHOT_CF_BITMAP, "Ptr")
		if !Borrowed
			throw Error("The admitted region clipboard contains no bitmap.")
		_GestureScreenshotNativeProbe("acquired", Borrowed)
		; Copy the valid shared CF_BITMAP under its lock. Flags zero makes a
		; private DDB, never the borrowed handle; GDI+ then makes its detached
		; copy before the clipboard lock is released.
		Private := DllCall("User32\CopyImage", "Ptr", Borrowed, "UInt", GESTURE_SCREENSHOT_IMAGE_BITMAP,
			"Int", 0, "Int", 0, "UInt", 0, "Ptr")
		if !Private
			throw Error("The admitted region bitmap could not be copied.")
		try {
			Image := _GestureScreenshotGdipFromHBitmap(Private)
		} finally {
			if !DllCall("Gdi32\DeleteObject", "Ptr", Private, "Int") {
				_GestureScreenshotGdipDispose(Image)
				Image := 0
				throw Error("The private region bitmap could not be released.")
			}
		}
	} finally {
		if !DllCall("User32\CloseClipboard", "Int") {
			_GestureScreenshotGdipDispose(Image)
			Image := 0
			throw Error("The region clipboard lock could not be released.")
		}
	}
	try {
		_GestureScreenshotNativeProbe("detached", 0)
		_GestureScreenshotGdipWrite(&Image, Stage, GESTURE_SCREENSHOT_PNG_ENCODER, MaxEdge)
	} finally {
		_GestureScreenshotGdipDispose(Image)
	}
}
