# static/drivers/hammerspoon/apps/App Cloner.app/Contents/Resources/tint_icon.py

"""
==============================================================================
MODULE: Icon Tinter
DESCRIPTION:
Applies a colour tint or greyscale conversion to a source PNG and writes the
result to a destination PNG, preserving the icon's original transparency.

FEATURES & RATIONALE:
1. Python subprocess: avoids all AppleScript-ObjC selector-colon and reserved-
   keyword parse issues that arise in osascript contexts.
2. The source PNG is written by the AppleScript caller (TIFF via
   NSImage.TIFFRepresentation, converted to PNG by sips), so this script
   never needs NSWorkspace or a display server.
3. Hue-mode tint (Photoshop-style): shifts the hue of coloured pixels toward
   the chosen colour while leaving whites, greys, and blacks untouched
   (their saturation is 0, so the Hue blend has no effect on them). Alpha
   from the colour well drives tint strength. DestinationIn then restores
   the original alpha channel — output stays fully transparent wherever the
   source icon was transparent.
4. Pure PyObjC stdlib — no Homebrew, no Xcode, no extra deps.

USAGE:
    tint_icon.py <src-png> <dst-png> <#RRGGBB> <tint|bw> <alpha-int-0-10000>

    alpha-int is the colour-well alpha multiplied by 10000 and rounded to the
    nearest integer, to sidestep locale-dependent decimal separators.

EXIT:
    0 on success, 1 on failure.
==============================================================================
"""

import sys


def main() -> int:
	"""Entry point.

	Returns:
		Exit code — 0 on success, 1 on failure.
	"""
	if len(sys.argv) != 6:
		sys.stderr.write("Usage: tint_icon.py <src.png> <dst.png> <#RRGGBB> <tint|bw> <alpha-int>\n")
		return 1

	src_path, dst_path, hex_color, mode, alpha_int_str = (
		sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
	)
	try:
		tint_alpha = max(0.0, min(1.0, int(alpha_int_str) / 10000.0))
	except ValueError:
		sys.stderr.write(f"Invalid alpha-int value: {alpha_int_str}\n")
		return 1

	from AppKit import (
		NSImage, NSBitmapImageRep, NSGraphicsContext, NSColor,
		NSBezierPath, NSCompositingOperationSourceOver,
		NSCompositingOperationDestinationIn,
		NSCompositingOperationHue,
		NSCompositingOperationSaturation,
		NSPNGFileType,
	)
	from Foundation import NSMakeRect, NSZeroRect


	# ==========================
	# ===== 1) Load source =====
	# ==========================

	src = NSImage.alloc().initWithContentsOfFile_(src_path)
	if src is None:
		sys.stderr.write(f"Failed to load source: {src_path}\n")
		return 1


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

	# Pass 1: draw source icon at full opacity to establish the base pixels.
	src.drawInRect_fromRect_operation_fraction_respectFlipped_hints_(
		dest_rect, NSZeroRect, NSCompositingOperationSourceOver, 1.0, True, None,
	)

	# Parse hex colour.
	hex_color = hex_color.lstrip("#")
	r = int(hex_color[0:2], 16) / 255.0
	g = int(hex_color[2:4], 16) / 255.0
	b = int(hex_color[4:6], 16) / 255.0

	# Pass 2: apply hue-mode tint (Photoshop-style) — replaces the hue of each
	# pixel with the chosen colour's hue while preserving saturation and
	# luminosity. Whites, greys, and blacks are unaffected because their
	# saturation is 0, so the Hue blend has nothing to shift.
	# bw mode uses Saturation blend to drain colour without changing lightness.
	# alpha drives strength via the fraction parameter of drawInRect.
	if mode == "bw":
		ctx.setCompositingOperation_(NSCompositingOperationSaturation)
		NSColor.colorWithWhite_alpha_(0.0, 1.0).setFill()
		NSBezierPath.fillRect_(dest_rect)
	else:
		# Draw the tint colour using the Hue compositing operation.
		# The fraction argument is not available on fillRect_, so we render the
		# colour into a temporary image and draw that at tint_alpha opacity.
		tint_bitmap = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
			None, size, size, 8, 4, True, False, "NSDeviceRGBColorSpace", 0, 32,
		)
		tint_ctx = NSGraphicsContext.graphicsContextWithBitmapImageRep_(tint_bitmap)
		NSGraphicsContext.saveGraphicsState()
		NSGraphicsContext.setCurrentContext_(tint_ctx)
		NSColor.colorWithRed_green_blue_alpha_(r, g, b, 1.0).setFill()
		NSBezierPath.fillRect_(dest_rect)
		NSGraphicsContext.restoreGraphicsState()
		NSGraphicsContext.setCurrentContext_(ctx)

		tint_img = NSImage.alloc().initWithSize_((size, size))
		tint_img.addRepresentation_(tint_bitmap)

		# Hue blend: shift hue of existing pixels toward the chosen colour.
		ctx.setCompositingOperation_(NSCompositingOperationHue)
		tint_img.drawInRect_fromRect_operation_fraction_respectFlipped_hints_(
			dest_rect, NSZeroRect, NSCompositingOperationHue, tint_alpha, True, None,
		)

	# Pass 3: restore the source's alpha so transparent regions stay
	# transparent — the output PNG has no white matte.
	src.drawInRect_fromRect_operation_fraction_respectFlipped_hints_(
		dest_rect, NSZeroRect, NSCompositingOperationDestinationIn, 1.0, True, None,
	)

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
