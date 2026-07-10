// tools/test/test-wpm-constants-single-source.cjs

/**
 * ==============================================================================
 * MODULE: WPM Widget Constants Single-Source Guard (#5)
 * DESCRIPTION:
 * The AHK WPMWidget_LoadSharedConst() reads shared TOML values via IniCacheGet
 * with hardcoded string defaults for every key (e.g. "80", "#0055cc", "0.40").
 * If a TOML key is renamed or removed, AHK silently serves the stale hardcoded
 * value while macOS fails fast. This gate pins every hardcoded default against
 * the canonical TOML so the two cannot silently drift.
 *
 * The macOS side is already pinned by test_wpm_shared_constants.lua (fail-fast,
 * no literal fallbacks). The macOS fallback colors in shared.lua were also
 * aligned to the TOML by #4.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static/ergopti_plus');

function read(rel) { return fs.readFileSync(path.join(SP, rel), 'utf8'); }

/** Simple TOML value extractor: key = value or key = "value" or key = 'value'. */
function tomlVal(toml, section, key) {
	const secRe = new RegExp('^\\[' + section.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\]', 'm');
	const secStart = toml.search(secRe);
	if (secStart === -1) return null;
	const after = toml.slice(secStart);
	const nextSec = after.slice(1).search(/^\[/m);
	const sectionBody = nextSec === -1 ? after : after.slice(0, nextSec + 1);
	const m = sectionBody.match(new RegExp('^' + key + '\\s*=\\s*(.+)', 'm'));
	if (!m) return null;
	let v = m[1].trim();
	v = v.replace(/^["'](.*)["']$/, '$1');
	return v;
}

/** Extracts an IniCacheGet hardcoded default from AHK source.
 *  Pattern: IniCacheGet(wpm_c, "section", "key", "default")
 *  Returns the default string (without quotes). */
function ahkDefault(src, section, key) {
	const re = new RegExp(
		'IniCacheGet\\(wpm_c,\\s*"' + section + '",\\s*"' + key + '",\\s*"([^"]*)"\\)'
	);
	const m = src.match(re);
	if (!m) return null;
	return m[1];
}

/** Extracts an IniCacheGet hardcoded default from AHK source (tim_c variant).
 *  Pattern: IniCacheGet(tim_c, "section", "key", "default") */
function ahkTimDefault(src, section, key) {
	const re = new RegExp(
		'IniCacheGet\\(tim_c,\\s*"' + section + '",\\s*"' + key + '",\\s*"([^"]*)"\\)'
	);
	const m = src.match(re);
	if (!m) return null;
	return m[1];
}

/** Extracts an else-branch hardcoded integer assignment from AHK source.
 *  Pattern: WPMWidgetConst.KEY := integer */
function ahkElseDefault(src, key) {
	const re = new RegExp('WPMWidgetConst\\.' + key + '\\s*:=\\s*(\\d+)');
	const m = src.match(re);
	if (!m) return null;
	return m[1];
}

/** Extracts the macOS COLOR_FALLBACK value from shared.lua.
 *  Pattern: manual = "#0055cc", llm = "#7a30b0" */
function macColorFallback(src, key) {
	const re = new RegExp(key + '\\s*=\\s*"([^"]+)"');
	const m = src.match(re);
	if (!m) return null;
	return m[1];
}

const errors = [];

try {
	const toml    = read('_shared/modules/wpm_widget/constants.toml');
	const ahkSrc  = read('windows/ui/wpm/wpm_config.ahk');
	const macSrc  = read('macos/ui/wpm/shared.lua');

	// ── #5: AHK hardcoded defaults vs shared TOML ──────────────────────────
	const ahkPairs = [
		{ section: 'compact', key: 'width' },
		{ section: 'compact', key: 'height' },
		{ section: 'compact', key: 'height_number' },
		{ section: 'compact', key: 'height_gap' },
		{ section: 'compact', key: 'height_unit' },
		{ section: 'compact', key: 'number_font_size' },
		{ section: 'compact', key: 'unit_font_size' },
		{ section: 'compact', key: 'unit_strip_darken_factor' },
		{ section: 'colors',  key: 'bg_manual' },
		{ section: 'colors',  key: 'bg_ai' },
		{ section: 'colors',  key: 'bg_idle' },
		{ section: 'colors',  key: 'text_active' },
		{ section: 'colors',  key: 'text_idle' },
		{ section: 'colors',  key: 'widget_hsl_l' },
		{ section: 'colors',  key: 'widget_hsl_s' },
		{ section: 'transparency', key: 'alpha_active' },
		{ section: 'transparency', key: 'alpha_idle' },
	];

	for (const p of ahkPairs) {
		const tomlV = tomlVal(toml, p.section, p.key);
		const ahkV  = ahkDefault(ahkSrc, p.section, p.key);

		if (tomlV === null) {
			errors.push(`TOML key not found: [${p.section}].${p.key}`);
			continue;
		}
		if (ahkV === null) {
			errors.push(`AHK default not found for: [${p.section}].${p.key}`);
			continue;
		}
		if (tomlV !== ahkV) {
			errors.push(
				`[${p.section}].${p.key}: TOML="${tomlV}" ≠ AHK default="${ahkV}". ` +
				`Update the hardcoded default in WPMWidget_LoadSharedConst() or the TOML.`
			);
		}
	}

	// ── #5b: AHK timings defaults (tim_c) vs shared timings TOML ──────────
	const timToml = read('_shared/modules/timings/constants.toml');
	const timPairs = [
		{ section: 'ui', key: 'wpm_widget_idle_hide_ms' },
		{ section: 'ui', key: 'wpm_color_hold_ms' },
	];

	for (const p of timPairs) {
		const tomlV = tomlVal(timToml, p.section, p.key);
		const ahkV  = ahkTimDefault(ahkSrc, p.section, p.key);

		if (tomlV === null) {
			errors.push(`Timings TOML key not found: [${p.section}].${p.key}`);
			continue;
		}
		if (ahkV === null) {
			errors.push(`AHK tim_c default not found for: [${p.section}].${p.key}`);
			continue;
		}
		if (tomlV !== ahkV) {
			errors.push(
				`Timings [${p.section}].${p.key}: TOML="${tomlV}" ≠ AHK default="${ahkV}". ` +
				`Update the hardcoded default in WPMWidget_LoadSharedConst() or the TOML.`
			);
		}

		// Also gate the else-branch hardcoded integer fallback.
		const keyName = p.key === 'wpm_widget_idle_hide_ms' ? 'IDLE_HIDE_MS' : 'COLOR_HOLD_MS';
		const elseV = ahkElseDefault(ahkSrc, keyName);
		if (elseV !== null && tomlV !== elseV) {
			errors.push(
				`Timings else-branch ${keyName}: TOML="${tomlV}" ≠ AHK hardcoded="${elseV}". ` +
				`Update the else-branch literal in WPMWidget_LoadSharedConst().`
			);
		}
	}

	// ── #4 gate: macOS COLOR_FALLBACK vs TOML canonical ────────────────────
	const colorFallbackPairs = [
		{ macKey: 'manual', tomlKey: 'bg_manual', tomlVal: '#0055cc' },
		{ macKey: 'llm',    tomlKey: 'bg_ai',     tomlVal: '#7a30b0' },
	];

	for (const p of colorFallbackPairs) {
		const macV = macColorFallback(macSrc, p.macKey);
		const tomlV = tomlVal(toml, 'colors', p.tomlKey);

		if (macV === null) {
			errors.push(`macOS COLOR_FALLBACK.${p.macKey} not found in shared.lua`);
			continue;
		}
		if (tomlV !== macV) {
			errors.push(
				`macOS COLOR_FALLBACK.${p.macKey}="${macV}" ≠ TOML [colors].${p.tomlKey}="${tomlV}". ` +
				`Fix: align shared.lua COLOR_FALLBACK with the TOML canonical.`
			);
		}
	}

} catch (e) {
	errors.push(e.message);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] WPM widget constants are not single-sourced:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log('\x1b[32m[OK] WPM widget constants — all AHK IniCacheGet defaults (wpm_c + tim_c), macOS COLOR_FALLBACK, and else-branch fallbacks match the shared TOML canonicals.\x1b[0m');
