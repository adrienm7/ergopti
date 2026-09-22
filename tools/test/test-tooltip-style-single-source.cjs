// tools/test/test-tooltip-style-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Tooltip Style Single Source
 * DESCRIPTION:
 * Pins the LLM prediction tooltip's look to _shared/modules/tooltip/constants.toml
 * on both the Windows and the macOS driver, so the two cannot drift apart again.
 *
 * WHY:
 * The Windows panel had drifted from macOS on every visible axis — width,
 * placement, spacing — while the TOML already existed, because a few values
 * were never read from it (caret_offset_x was a literal 15, the font name a
 * literal "Segoe UI", window_offset_y and screen_margin unread) and nothing
 * compared the drivers' readers. This gate asserts three things:
 *   1. every style key below is read through each driver's TOML accessor
 *      (AHK _UiStyleRequire, Lua require_key), never retyped;
 *   2. the AHK style globals start as empty sentinels — a literal initial value
 *      would be a second, silent source when the loader is bypassed;
 *   3. each "#RRGGBB" companion AHK reads equals the RGBA/white value macOS
 *      reads, so the same key cannot mean two colours on two drivers.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const TOML = fs.readFileSync(path.join(SP, '_shared', 'modules', 'tooltip', 'constants.toml'), 'utf8');
const AHK = fs.readFileSync(path.join(SP, 'windows', 'infra', 'ui_style.ahk'), 'utf8');
const LUA = fs.readFileSync(path.join(SP, 'macos', 'ui', 'tooltip', 'config.lua'), 'utf8');

const errors = [];

/** Flat [section] → { key: raw value } map; enough for this file's shape. */
function parseToml(src) {
	const out = {};
	let section = null;
	for (const raw of src.split('\n')) {
		const line = raw.trim();
		if (line === '' || line.startsWith('#')) continue;
		const header = /^\[([a-z_]+)\]/.exec(line);
		if (header) {
			section = header[1];
			out[section] = {};
			continue;
		}
		const kv = /^([a-z_0-9]+)\s*=\s*(.+)$/.exec(line);
		if (kv && section) out[section][kv[1]] = kv[2].replace(/\s+#.*$/, '').trim();
	}
	return out;
}
const toml = parseToml(TOML);

// Keys both drivers must read (layout units / shared values).
const SHARED = [
	['layout', 'pad_x'],
	['layout', 'pad_y'],
	['layout', 'line_spacing'],
	['layout', 'hint_spacing'],
	['layout', 'corner_radius'],
	['layout', 'screen_margin'],
	['positioning', 'caret_offset_x'],
	['positioning', 'caret_offset_y'],
	['positioning', 'window_offset_y'],
	['positioning', 'max_caret_height'],
	['llm_ui', 'active_prefix'],
	['llm_ui', 'slot_placeholder'],
	['llm_ui', 'inactive_align_char'],
	['llm_ui', 'footer_space_divider'],
	['llm_ui', 'footer_combined_separator'],
	['llm_ui', 'shortcut_label_gap'],
	['tint', 'lightness'],
	['tint', 'saturation']
];

// [section, AHK key, macOS key] — one visual value, one platform spelling each.
const PAIRED = [
	['typography', 'font_main_ahk', 'font_main_hs'],
	['typography', 'font_size_main_ahk', 'font_size_main_hs'],
	['typography', 'font_size_hint_ahk', 'font_size_hint_hs'],
	['typography', 'font_size_info_ahk', 'font_size_info_hs'],
	['colors', 'bg_hex', 'bg_white'],
	['colors', 'hint_hex', 'hint_white'],
	['colors', 'info_hex', 'info_white'],
	['colors', 'loading_text_hex', 'loading_text_white'],
	['llm_colors', 'corr_sel_hex', 'corr_sel'],
	['llm_colors', 'nw_sel_hex', 'nw_sel'],
	['llm_colors', 'unsel_gray_hex', 'unsel_gray'],
	['llm_colors', 'loading_hex', 'loading'],
	['llm_colors', 'cursor_hex', 'cursor'],
	['llm_colors', 'cmd_sel_hex', 'cmd_sel'],
	['llm_colors', 'cmd_dim_hex', 'cmd_dim'],
	['accent_colors', 'ai_loading_hex', 'ai_loading']
];

const ahkReads = (section, key) =>
	new RegExp(`_UiStyleRequire(?:Hex)?\\(c,\\s*"${section}",\\s*"${key}"\\)`).test(AHK);
const luaReads = (section, key) => new RegExp(`require_key\\("${section}",\\s*"${key}"\\)`).test(LUA);

function declared(section, key) {
	if (!toml[section] || !(key in toml[section])) {
		errors.push(`[${section}].${key} is not declared in constants.toml`);
		return false;
	}
	return true;
}

for (const [section, key] of SHARED) {
	if (!declared(section, key)) continue;
	if (!ahkReads(section, key)) errors.push(`Windows does not read [${section}].${key} through _UiStyleRequire`);
	if (!luaReads(section, key)) errors.push(`macOS does not read [${section}].${key} through require_key`);
}

/** RGB triple in 0..255 from a TOML value: "#RRGGBB", a number (white), or an inline table. */
function rgb(raw) {
	const hex = /^"#([0-9A-Fa-f]{6})"$/.exec(raw);
	if (hex) return [0, 2, 4].map((i) => parseInt(hex[1].slice(i, i + 2), 16));
	if (/^[0-9.]+$/.test(raw)) return Array(3).fill(Math.round(parseFloat(raw) * 255));
	const member = (name) => {
		const m = new RegExp(`\\b${name}\\s*=\\s*([0-9.]+)`).exec(raw);
		return m ? Math.round(parseFloat(m[1]) * 255) : null;
	};
	if (member('white') !== null) return Array(3).fill(member('white'));
	return [member('red'), member('green'), member('blue')];
}

for (const [section, ahkKey, hsKey] of PAIRED) {
	if (!declared(section, ahkKey) || !declared(section, hsKey)) continue;
	if (!ahkReads(section, ahkKey)) errors.push(`Windows does not read [${section}].${ahkKey} through _UiStyleRequire`);
	if (!luaReads(section, hsKey)) errors.push(`macOS does not read [${section}].${hsKey} through require_key`);
	if (!ahkKey.endsWith('_hex')) continue;
	const a = rgb(toml[section][ahkKey]);
	const b = rgb(toml[section][hsKey]);
	if (a.some((v, i) => v === null || b[i] === null || Math.abs(v - b[i]) > 1)) {
		errors.push(
			`[${section}] ${ahkKey} = ${toml[section][ahkKey]} (Windows) and ${hsKey} = ${toml[section][hsKey]} ` +
				'(macOS) are different colours — update both companions together'
		);
	}
}

// Style globals must start empty: a literal is a second source that silently
// wins whenever the loader is skipped (the old UI_OFFSET_RIGHT := 15).
const STYLE_GLOBALS = [
	'UI_FONT_NAME', 'UI_FONT_SIZE_MAIN', 'UI_FONT_SIZE_HINT', 'UI_FONT_SIZE_INFO', 'UI_PAD_X', 'UI_PAD_Y',
	'UI_LINE_SPACING', 'UI_HINT_SPACING', 'UI_CORNER_RADIUS', 'UI_BG_HEX', 'UI_HINT_COLOR_HEX',
	'UI_INFO_COLOR_HEX', 'UI_LOADING_TEXT_HEX', 'UI_OFFSET_BELOW', 'UI_OFFSET_RIGHT', 'UI_WINDOW_OFFSET_Y',
	'UI_SCREEN_MARGIN', 'UI_MAX_CARET_HEIGHT_PX', 'UI_LLM_CORR_SEL_HEX', 'UI_LLM_NW_SEL_HEX',
	'UI_LLM_UNSEL_GRAY_HEX', 'UI_LLM_LOADING_HEX', 'UI_LLM_CURSOR_HEX', 'UI_LLM_CMD_SEL_HEX',
	'UI_LLM_CMD_DIM_HEX', 'UI_AI_LOADING_HEX'
];
for (const name of STYLE_GLOBALS) {
	const init = new RegExp(`^global ${name}\\s*:=\\s*(\\S+)`, 'm').exec(AHK);
	if (!init) {
		errors.push(`ui_style.ahk no longer declares ${name} at file scope`);
		continue;
	}
	if (init[1] !== '0' && init[1] !== '""') {
		errors.push(`ui_style.ahk initialises ${name} to ${init[1]} — style globals start as 0 / "" sentinels`);
	}
}

// The Windows renderers must not carry their own margin or colour literals.
const HELPERS = fs.readFileSync(path.join(SP, 'windows', 'ui', 'tooltip', 'helpers.ahk'), 'utf8');
const LLM = fs.readFileSync(path.join(SP, 'windows', 'ui', 'tooltip', 'llm.ahk'), 'utf8');
if (/static\s+MARGIN\s*:=/.test(HELPERS)) {
	errors.push('ui/tooltip/helpers.ahk declares its own MARGIN; read [layout].screen_margin');
}
const rendererStart = LLM.indexOf('_LLM_TooltipFooterTexts() {');
if (rendererStart === -1) errors.push('ui/tooltip/llm.ahk no longer defines _LLM_TooltipFooterTexts; re-anchor this scan');
const llmRenderer = rendererStart === -1 ? '' : LLM.slice(rendererStart);
const literal = /"[^"\n]*\bc[0-9A-Fa-f]{6}\b[^"\n]*"/.exec(llmRenderer);
if (literal) errors.push(`the LLM renderer hardcodes a colour (${literal[0]}); read it from constants.toml`);

if (errors.length) {
	console.error('\x1b[31m[ERROR] tooltip style single source:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] tooltip style: ${SHARED.length} shared and ${PAIRED.length} paired keys read by both ` +
		'drivers from constants.toml; hex companions match their macOS colours.\x1b[0m'
);
