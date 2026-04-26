#!/usr/bin/env python3
"""
==============================================================================
MODULE: Icon Extractor
DESCRIPTION:
Renders a macOS application's icon as a high-resolution PNG.

FEATURES & RATIONALE:
1. iconutil-first pipeline: matches what clone_app.sh uses for the actual
   generated clone icon, so the live tint preview is pixel-identical to the
   final result. NSImage.initWithContentsOfFile_ on an .icns sometimes picks
   a placeholder representation for Microsoft Teams and similar apps; the
   raw PNGs unpacked by `iconutil -c iconset` are always correct.
2. NSWorkspace fallback: covers App Store apps whose icon lives in
   Assets.car instead of a plain .icns.
3. Pure stdlib + system PyObjC — runs on any macOS install with
   /usr/bin/python3 available (no Xcode, no Homebrew, no extra deps).

USAGE:
    extract_icon.py <app-bundle-path> <output-png-path>

EXIT:
    0 on success, non-zero on failure (caller should show its own fallback).
==============================================================================
"""

import os
import shutil
import subprocess
import sys
import tempfile




# ==========================================
# ==========================================
# ======= 1/ iconutil extraction ===========
# ==========================================
# ==========================================

# Sizes we try in priority order — largest first so the preview is sharp
# even when scaled down to 128 px in the colour-picker panel.
_PREFERRED_SIZES = (
	"icon_512x512@2x", "icon_512x512",
	"icon_256x256@2x", "icon_256x256",
	"icon_128x128@2x", "icon_128x128",
)


def _resolve_icns(app_path: str) -> str:
	"""Locate the bundle's .icns file, mirroring clone_app.sh's lookup order.

	Args:
		app_path: Absolute path to the .app bundle.

	Returns:
		Absolute path to a .icns file, or "" if none was found.
	"""
	# CFBundleIconFile is the documented way; covers most apps
	info_plist = os.path.join(app_path, "Contents", "Info.plist")
	icon_name = ""
	try:
		result = subprocess.run(
			["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIconFile", info_plist],
			capture_output=True, text=True,
		)
		if result.returncode == 0:
			icon_name = result.stdout.strip()
	except Exception:
		pass

	if icon_name:
		if not icon_name.lower().endswith(".icns"):
			icon_name += ".icns"
		candidate = os.path.join(app_path, "Contents", "Resources", icon_name)
		if os.path.isfile(candidate):
			return candidate

	# Fallback: glob the Resources folder for any .icns. Catches apps whose
	# Info.plist points at a name that does not match the actual filename.
	resources = os.path.join(app_path, "Contents", "Resources")
	try:
		for entry in os.listdir(resources):
			if entry.lower().endswith(".icns"):
				return os.path.join(resources, entry)
	except Exception:
		pass

	return ""


def extract_via_iconutil(app_path: str, dst: str) -> bool:
	"""Extract the largest available PNG from the bundle's .icns.

	Same path clone_app.sh uses for clone-icon generation. Picking the
	pre-rendered PNG inside the .icns avoids NSImage's representation
	picker, which can land on an alpha-only mask for some sandboxed apps.

	Args:
		app_path: Absolute path to the .app bundle.
		dst:      Destination PNG path to write.

	Returns:
		True when a PNG was successfully written.
	"""
	icns = _resolve_icns(app_path)
	if not icns:
		return False

	tmpdir = tempfile.mkdtemp(prefix="appcloner_iconprev_")
	try:
		iconset = os.path.join(tmpdir, "src.iconset")
		result = subprocess.run(
			["iconutil", "-c", "iconset", icns, "-o", iconset],
			capture_output=True,
		)
		if result.returncode != 0 or not os.path.isdir(iconset):
			return False
		for size in _PREFERRED_SIZES:
			png = os.path.join(iconset, f"{size}.png")
			if os.path.isfile(png):
				shutil.copy(png, dst)
				return True
	finally:
		shutil.rmtree(tmpdir, ignore_errors=True)

	return False




# ============================================
# ============================================
# ======= 2/ NSWorkspace fallback ============
# ============================================
# ============================================

def extract_via_nsworkspace(app_path: str, dst: str) -> bool:
	"""Render the app's icon via NSWorkspace.iconForFile_.

	Used when the bundle has no usable .icns (App Store apps storing
	their icon in Assets.car). The pre-rendered raster comes from
	LaunchServices' icon cache, which is fully populated when invoked
	from a fresh /usr/bin/python3 process.

	Args:
		app_path: Absolute path to the .app bundle.
		dst:      Destination PNG path to write.

	Returns:
		True when a PNG was successfully written.
	"""
	from AppKit import (
		NSWorkspace, NSBitmapImageRep, NSPNGFileType, NSGraphicsContext,
		NSDeviceRGBColorSpace, NSCompositingOperationCopy,
	)
	from Foundation import NSMakeRect

	img = NSWorkspace.sharedWorkspace().iconForFile_(app_path)
	if img is None:
		return False

	# Pick the largest representation NSImage holds so we render the
	# sharpest version it has cached.
	reps = img.representations()
	best = None
	for r in reps:
		if best is None or r.pixelsWide() > best.pixelsWide():
			best = r
	target = max(best.pixelsWide() if best else 512, 512)

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
		return False
	return bool(png.writeToFile_atomically_(dst, True))




# ==================================
# ==================================
# ======= 3/ Entry Point ===========
# ==================================
# ==================================

if __name__ == "__main__":
	if len(sys.argv) != 3:
		sys.stderr.write("Usage: extract_icon.py <app-path> <output-png>\n")
		sys.exit(2)
	app_path, dst_path = sys.argv[1], sys.argv[2]
	if extract_via_iconutil(app_path, dst_path):
		sys.exit(0)
	if extract_via_nsworkspace(app_path, dst_path):
		sys.exit(0)
	sys.exit(1)
