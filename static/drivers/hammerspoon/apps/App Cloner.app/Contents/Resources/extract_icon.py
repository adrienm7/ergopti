#!/usr/bin/env python3
"""
==============================================================================
MODULE: Icon Extractor
DESCRIPTION:
Renders a macOS application's icon as a high-resolution PNG.

FEATURES & RATIONALE:
1. LaunchServices-aware: runs in a fresh /usr/bin/python3 process so
   NSWorkspace.iconForFile_ resolves sandboxed apps and asset-catalog
   icons correctly. AppleScript-ObjC's NSWorkspace, called from osascript,
   returns a near-empty placeholder for apps like Microsoft Teams, Outlook,
   Safari (Tahoe and later) — making the live tint preview look blank.
2. Best-rep selection: scans every NSImageRep on the icon and renders into
   a bitmap sized after the largest one (or 512 px minimum), forcing
   NSImage to materialize the highest-quality representation it has cached.
3. Pure stdlib + system PyObjC: no external dependencies, runs on any
   macOS install with /usr/bin/python3 available.

USAGE:
    extract_icon.py <app-bundle-path> <output-png-path>
==============================================================================
"""

import sys
from AppKit import (
	NSWorkspace, NSBitmapImageRep, NSPNGFileType, NSGraphicsContext,
	NSDeviceRGBColorSpace, NSCompositingOperationCopy,
)
from Foundation import NSMakeRect


# ====================================
# ====================================
# ======= 1/ Icon Resolution =========
# ====================================
# ====================================

def render_icon(app_path: str, dst_path: str) -> int:
	"""Render the app's icon to a PNG file at dst_path.

	Args:
		app_path: Absolute path to the .app bundle.
		dst_path: Absolute path of the PNG file to write.

	Returns:
		0 on success, 1 on failure.
	"""
	# Ask NSWorkspace for the icon — works across all icon storage formats
	# (legacy .icns, asset catalog, document-icon plug-ins).
	img = NSWorkspace.sharedWorkspace().iconForFile_(app_path)
	if img is None:
		return 1

	# Pick the largest representation NSImage holds. Without this step
	# drawInRect: tends to pick a small cached rep and upscale it, producing
	# a blurry/empty result for apps that store the icon in Assets.car.
	reps = img.representations()
	best = None
	for r in reps:
		if best is None or r.pixelsWide() > best.pixelsWide():
			best = r
	target = max(best.pixelsWide() if best else 512, 512)

	# Render into a fresh RGBA bitmap. Operation Copy + respectFlipped:True
	# guarantees a clean redraw regardless of how the source rep is cached.
	bitmap = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
		None, target, target, 8, 4, True, False,
		NSDeviceRGBColorSpace, 0, 32,
	)
	ctx = NSGraphicsContext.graphicsContextWithBitmapImageRep_(bitmap)
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.setCurrentContext_(ctx)
	img.drawInRect_fromRect_operation_fraction_respectFlipped_hints_(
		NSMakeRect(0, 0, target, target),
		NSMakeRect(0, 0, 0, 0),
		NSCompositingOperationCopy,
		1.0, True, None,
	)
	NSGraphicsContext.restoreGraphicsState()

	png = bitmap.representationUsingType_properties_(NSPNGFileType, None)
	if png is None:
		return 1
	png.writeToFile_atomically_(dst_path, True)
	return 0




# ==================================
# ==================================
# ======= 2/ Entry Point ===========
# ==================================
# ==================================

if __name__ == "__main__":
	if len(sys.argv) != 3:
		sys.stderr.write("Usage: extract_icon.py <app-path> <output-png>\n")
		sys.exit(2)
	sys.exit(render_icon(sys.argv[1], sys.argv[2]))
