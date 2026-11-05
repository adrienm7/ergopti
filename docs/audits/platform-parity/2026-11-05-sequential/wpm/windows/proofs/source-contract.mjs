import fs from 'node:fs';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
const root = process.argv[2];
assert(root, 'Pass pinned worktree root');
const read = (p) => fs.readFileSync(`${root}/${p}`, 'utf8');
const win = 'static/ergopti_plus/windows/';
const paths = {
	boot: win + 'ErgoptiPlus.ahk',
	display: win + 'ui/wpm/wpm_display.ahk',
	widget: win + 'ui/wpm/wpm_widget.ahk',
	config: win + 'ui/wpm/wpm_config.ahk',
	menu: win + 'ui/menu/menu_metrics_actions.ahk',
	gr: win + 'adapters/graphics_renderer.ahk',
	decl: 'static/ergopti_plus/_shared/modules/menu/menu.toml',
	model: 'static/ergopti_plus/_shared/lua/wpm_widget/model.lua',
	live: 'static/ergopti_plus/_shared/lua/keystats/live_wpm.lua',
	hs: 'static/ergopti_plus/macos/modules/keystats/init.lua'
};
const s = Object.fromEntries(Object.entries(paths).map(([k, p]) => [k, read(p)]));
function body(key, name) {
	const start = s[key].search(new RegExp('^' + name + '\\(', 'm'));
	assert(start >= 0, name + ' exists');
	const end = s[key].indexOf('\n}', start);
	assert(end > start, name + ' closes');
	return s[key].slice(start, end + 2);
}
function excerpt(key, needle, before = 2, after = 5) {
	const lines = s[key].split('\n');
	let matches = 0;
	for (let i = 0; i < lines.length; i++) {
		if (!lines[i].includes(needle)) continue;
		matches++;
		console.log(`${paths[key]}:${i + 1}`);
		for (let j = Math.max(0, i - before); j <= Math.min(lines.length - 1, i + after); j++)
			console.log(`${j + 1}: ${lines[j]}`);
	}
	assert(matches > 0, 'nonvacuous excerpt ' + needle);
}
console.log(
	'PROVENANCE: Node source-contract checks only. No AHK, HWND, native Windows timers, GDI, desktop or user interactions executed. Projected transitions in report are source deductions, not measured runtime.'
);
for (const [k, p] of Object.entries(paths))
	console.log(`sha256 ${crypto.createHash('sha256').update(s[k]).digest('hex')} ${p}`);
const show = body('display', 'WPMWidget_Show'),
	hide = body('display', 'WPMWidget_Hide');
assert(s.boot.includes('SetTimer(WPMWidget_Show, -WPMWidgetConst.BOOT_SHOW_DELAY_MS)'));
assert(s.display.includes('static BOOT_SHOW_DELAY_MS := 2500'));
assert(show.includes('WPMWidget.visible := true'));
assert(!hide.includes('SetTimer(WPMWidget_Show, 0)'));
assert(!/if\s+!?WPMWidget\.visible/.test(show));
assert(
	s.boot.indexOf('_TrayStartupCommands.NotifyReady()') <
		s.boot.indexOf('SetTimer(WPMWidget_Show, -WPMWidgetConst.BOOT_SHOW_DELAY_MS)')
);
assert(s.decl.includes('id = "wpm_widget"'));
console.log(
	'WPMW-001 source contract: ready/public menu precedes armed +2500ms Show; Hide never cancels it; callback publishes true without validating latest preference.'
);
excerpt('boot', '_TrayStartupCommands.NotifyReady()', 2, 8);
excerpt('boot', 'SetTimer(WPMWidget_Show,', 6, 2);
excerpt('display', 'WPMWidget_Show() {', 0, 25);
excerpt('display', 'WPMWidget_Hide() {', 0, 13);
excerpt('decl', 'id = "wpm_widget"', 1, 4);
excerpt('menu', 'Toggled := HasMethod(ToggleFn', 0, 5);
const render = body('widget', 'WPMWidget_RenderGraph'),
	gr = body('gr', '_GRDrawBitmapRun');
assert(render.includes('GR_DrawBitmap(g.Hwnd, DrawFn)\n\t\t\t\treturn true'));
assert(gr.includes('Succeeded := Native.UpdateLayeredWindow'));
assert(gr.includes('return Succeeded == true and Released'));
assert(!/(Logger(?:Error|Warn)|ConfigReport|Notify|OnError)\(/.test(s.gr));
assert(
	body('display', 'WPMWidget_Tick').includes(
		'if !WPMWidget_RenderGraph(label, accent)\n                return\n            GR_Show'
	)
);
console.log(
	'WPMW-002 source contract: native upload false is a returned receipt; no lower error/notification observer; renderer discards receipt and publishes true, tick reveals retained surface.'
);
excerpt('gr', 'Succeeded := Native.UpdateLayeredWindow', 1, 8);
excerpt('widget', 'GR_DrawBitmap(g.Hwnd, DrawFn)', 2, 5);
excerpt('display', 'if !WPMWidget_RenderGraph(label, accent)', 2, 7);
excerpt('display', 'Graph window pre-warmed', 5, 3);
const push = body('display', 'WPMWidget_Push'),
	color = body('display', 'WPMWidget_ResolveBgColor');
assert(push.includes('WPMWidget._last_ai_tick := now_t'));
assert(push.includes('WPMWidget._last_hs_tick := now_t'));
assert(color.indexOf('if has_ai') < color.indexOf('if has_hs'));
assert(s.live.includes('tracker.source = source'));
assert(s.hs.includes('CoreState.last_source_type    = source_type'));
assert(s.model.includes('local source = stats.source_variant or stats.source or "none"'));
console.log(
	'WPMW-003 source contract: independent source holds and AI-first precedence on Windows; last accepted source replaces prior source on Lua producers.'
);
excerpt('display', 'if has_ai', 1, 10);
excerpt('display', 'WPMWidget._last_hs_tick := now_t', 2, 10);
excerpt('model', 'function M.active_source', 0, 8);
excerpt('live', 'tracker.source = source', 1, 5);
excerpt('hs', 'CoreState.last_source_type    = source_type', 1, 4);
console.log('PASS: three nonvacuous source-contract claims; zero Windows execution claims.');
