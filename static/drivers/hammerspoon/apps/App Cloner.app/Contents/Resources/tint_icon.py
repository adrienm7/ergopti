# static/drivers/hammerspoon/apps/App Cloner.app/Contents/Resources/tint_icon.py

"""
==============================================================================
MODULE: Icon Tinter
DESCRIPTION:
Extracts a macOS app icon and applies a colour tint or greyscale conversion,
writing the result to a destination PNG.

FEATURES & RATIONALE:
1. Python subprocess: avoids all AppleScript-ObjC selector-colon and reserved-
   keyword parse issues that arise in osascript contexts.
2. Reuses extract_icon.py: the same icon extraction pipeline used by
   clone_app.sh, so the preview is pixel-identical to the final result.
3. 4-pass compositing: Normal draw, Multiply/Saturation tint, DestinationIn
   alpha mask, DestinationOver white matte.
4. Pure PyObjC stdlib — no Homebrew, no Xcode, no extra deps.

USAGE:
    tint_icon.py <app-bundle-path> <dst-png> <#RRGGBB> <tint|bw>

EXIT:
    0 on success, 1 on failure.
==============================================================================
"""

import os
import subprocess
import sys
import tempfile


def _extract_icon(app_path: str, dst_png: str) -> bool:
	"""Extract the app icon to dst_png using extract_icon.py.

	Args:
		app_path: Absolute path to the .app bundle.
		dst_png:  Destination PNG path.

	Returns:
		True on success.
	"""
	script_dir = os.path.dirname(os.path.abspath(__file__))
	extractor = os.path.join(script_dir, "extract_icon.py")
	result = subprocess.run(
		["/usr/bin/python3", extractor, app_path, dst_png],
		capture_output=True,
	)
	return result.returncode == 0 and os.path.isfile(dst_png)


def main() -> int:
	"""Entry point.

	Returns:
		Exit code — 0 on success, 1 on failure.
	"""
	if len(sys.argv) != 5:
		sys.stderr.write("Usage: tint_icon.py <app-path> <dst.png> <#RRGGBB> <tint|bw>\n")
		return 1

	app_path, dst_path, hex_color, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

	from AppKit import (
		NSImage, NSBitmapImageRep, NSGraphicsContext, NSColor,
		NSBezierPath, NSCompositingOperationSourceOver,
		NSCompositingOperationMultiply, NSCompositingOperationDestinationIn,
		NSCompositingOperationDestinationOver, NSCompositingOperationSaturation,
		NSPNGFileType,
	)
	from Foundation import NSMakeRect, NSZeroRect


	# ================================
	# ===== 1) Extract app icon =====
	# ================================

	tmpdir = tempfile.mkdtemp(prefix="appcloner_tint_")
	src_png = os.path.join(tmpdir, "src.png")
	try:
		if not _extract_icon(app_path, src_png):
			sys.stderr.write(f"Icon extraction failed for: {app_path}\n")
			return 1

		src = NSImage.alloc().initWithContentsOfFile_(src_png)
		if src is None:
			sys.stderr.write(f"Failed to load extracted icon: {src_png}\n")
			return 1
	finally:
		import shutil
		shutil.rmtree(tmpdir, ignore_errors=True)


	# ===========================
	# ===== 2) Build canvas =====
	# ===========================

	size = 128
	bitmap = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
		None, size, size, 8, 4, True, False, "NSDeviceRGBColorSpace", 0, 32,
	)
	ctx = NSGraphicsContext.graphicsContextWithBitmapImageRep_(bitmap)
	if ctx is None:
		sys.stderr.write("Failed to create graphics context\n")
		return 1

	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.setCurrentContext_(ctx)

	dest_rect = NSMakeRect(0, 0, size, size)

	# Pass 1: draw source (forces rasterisation).
	src.drawInRect_fromRect_operation_fraction_respectFlipped_hints_(
		dest_rect, NSZeroRect, NSCompositingOperationSourceOver, 1.0, True, None,
	)

	# Parse hex colour.
	hex_color = hex_color.lstrip("#")
	r = int(hex_color[0:2], 16) / 255.0
	g = int(hex_color[2:4], 16) / 255.0
	b = int(hex_color[4:6], 16) / 255.0

	# Pass 2: tint or greyscale.
	if mode == "bw":
		ctx.setCompositingOperation_(NSCompositingOperationSaturation)
		NSColor.colorWithWhite_alpha_(0.5, 1.0).setFill()
		NSBezierPath.fillRect_(dest_rect)
	else:
		ctx.setCompositingOperation_(NSCompositingOperationMultiply)
		NSColor.colorWithRed_green_blue_alpha_(r, g, b, 1.0).setFill()
		NSBezierPath.fillRect_(dest_rect)

	# Pass 3: restore alpha mask (DestinationIn).
	src.drawInRect_fromRect_operation_fraction_respectFlipped_hints_(
		dest_rect, NSZeroRect, NSCompositingOperationDestinationIn, 1.0, True, None,
	)

	# Pass 4: white matte behind (DestinationOver).
	ctx.setCompositingOperation_(NSCompositingOperationDestinationOver)
	NSColor.whiteColor().setFill()
	NSBezierPath.fillRect_(dest_rect)

	NSGraphicsContext.restoreGraphicsState()


	# ============================
	# ===== 3) Write output =====
	# ============================

	png_data = bitmap.representationUsingType_properties_(NSPNGFileType, None)
	if png_data is None:
		sys.stderr.write("Failed to encode PNG\n")
		return 1
	if not png_data.writeToFile_atomically_(dst_path, True):
		sys.stderr.write(f"Failed to write: {dst_path}\n")
		return 1

	return 0


if __name__ == "__main__":
	sys.exit(main())
