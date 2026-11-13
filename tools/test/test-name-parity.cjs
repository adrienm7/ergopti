// tools/test/test-name-parity.cjs

/**
 * ==============================================================================
 * MODULE: Cross-Driver Name-Parity Guard
 * DESCRIPTION:
 * Regression guard ensuring the cross-driver symmetry renames stay in effect and
 * cannot silently regress. Checks three invariants:
 *
 * 1. text_utils — windows/core/text/engine/utils.ahk mirrors macos/core/text/engine/utils.lua
 *    (old name string_utils.ahk must be absent).
 * 2. action_picker — both drivers use a ui/action_picker/init.{ahk,lua} folder
 *    layout (old flat ui/action_picker.ahk must be absent).
 * 3. manifest_menu — windows/menu/engine/manifest_menu.ahk mirrors
 *    macos/menu/engine/manifest_menu.lua (the renderer file; already symmetric, guard
 *    ensures it is never accidentally reverted or renamed).
 *
 * ROOT CAUSE ENCODED:
 * Earlier the AHK driver used infra/string_utils.ahk while macOS used
 * infra/text_utils.lua (backed by _shared/core/text/engine/utils_core.lua). The flat
 * ui/action_picker.ahk had no Windows-side folder structure unlike the macOS
 * ui/action_picker/init.lua. Both divergences made cross-driver navigation
 * harder. This guard fails the JS suite whenever a regression reintroduces
 * either inconsistency.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WIN = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const MAC = path.join(ROOT, 'static', 'ergopti_plus', 'macos');

let failures = 0;

function check(label, condition, detail) {
	if (!condition) {
		console.error(`  FAIL: ${label}`);
		if (detail) console.error(`        ${detail}`);
		failures++;
	}
}

function exists(rel) {
	return fs.existsSync(path.join(ROOT, 'static', 'ergopti_plus', rel));
}

// =====================================================================
// =====================================================================
// ======= 1/ text_utils parity (windows ↔ macos) =============
// =====================================================================
// =====================================================================

check(
	'windows/core/text/engine/utils.ahk exists',
	exists('windows/core/text/engine/utils.ahk'),
	'Rename windows/shortcuts/engine/string_utils.ahk -> text_utils.ahk may have been reverted.'
);

check(
	'macos/core/text/engine/utils.lua exists',
	exists('macos/core/text/engine/utils.lua'),
	'macos/core/text/engine/utils.lua is the macOS peer — must not be renamed or removed.'
);

check(
	'windows/shortcuts/engine/string_utils.ahk is absent (old name, §5.6)',
	!exists('windows/shortcuts/engine/string_utils.ahk'),
	'Old name re-introduced — remove it and ensure infra/text_utils.ahk is the only copy.'
);

// =====================================================================
// =====================================================================
// ======= 2/ action_picker folder parity (windows ↔ macos) ===
// =====================================================================
// =====================================================================

check(
	'windows/shortcuts/ui/action_picker/init.ahk exists',
	exists('windows/shortcuts/ui/action_picker/init.ahk'),
	'Move windows/ui/action_picker.ahk -> ui/action_picker/init.ahk may have been reverted.'
);

check(
	'macos/shortcuts/ui/action_picker/init.lua exists',
	exists('macos/shortcuts/ui/action_picker/init.lua'),
	'macos/shortcuts/ui/action_picker/init.lua is the macOS peer — must not be renamed or removed.'
);

check(
	'windows/ui/action_picker.ahk is absent (old flat path, §5.6)',
	!exists('windows/ui/action_picker.ahk'),
	'Old flat file re-introduced — remove it and ensure ui/action_picker/init.ahk is the only copy.'
);

// =====================================================================
// =====================================================================
// ======= 3/ manifest_menu renderer parity (windows ↔ macos) =
// =====================================================================
// =====================================================================

check(
	'windows/menu/engine/manifest_menu.ahk exists (renderer, peer of manifest_menu.lua)',
	exists('windows/menu/engine/manifest_menu.ahk'),
	'windows/menu/engine/manifest_menu.ahk (the menu renderer) must not be renamed or removed.'
);

check(
	'macos/menu/engine/manifest_menu.lua exists',
	exists('macos/menu/engine/manifest_menu.lua'),
	'macos/menu/engine/manifest_menu.lua is the macOS renderer peer — must not be renamed or removed.'
);

// =====================================================================
// =====================================================================
// ======= 4/ Result ===================================================
// =====================================================================
// =====================================================================

if (failures === 0) {
	console.log(`name-parity: all ${8} symmetry invariant(s) hold.`);
	process.exit(0);
} else {
	console.error(`\nname-parity: ${failures} invariant(s) violated — see above.`);
	process.exit(1);
}
