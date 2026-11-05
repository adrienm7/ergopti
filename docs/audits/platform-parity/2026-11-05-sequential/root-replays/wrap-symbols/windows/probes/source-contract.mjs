import fs from 'node:fs';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
const root = process.argv[2];
assert(root);
const prefix = 'static/ergopti_plus/windows/';
const files = {
	config: prefix + 'infra/wrap_symbols_config.ahk',
	menu: prefix + 'ui/menu/menu_shortcuts.ahk',
	layout: prefix + 'modules/keymap/layout.ahk',
	worker: prefix + 'adapters/uia_worker.ahk',
	owner: prefix + 'modules/keymap/uia_selection_worker.ahk',
	send: prefix + 'infra/hotstrings/hotstring_send.ahk',
	hook: prefix + 'infra/hotstrings/hotstring_inputhook.ahk',
	vendor: prefix + 'vendor/UIA.ahk',
	pairs: prefix + 'infra/wrap_pair.ahk',
	catalogue: 'static/ergopti_plus/_shared/modules/wrap_symbols/wrap_symbols.json'
};
const s = Object.fromEntries(
	Object.entries(files).map(([k, p]) => [k, fs.readFileSync(root + '/' + p, 'utf8')])
);
function body(k, n) {
	const a = s[k].search(new RegExp('^' + n + '\\(', 'm'));
	assert(a >= 0, n + ' exists');
	const z = s[k].indexOf('\n}', a);
	assert(z > a, n + ' closes');
	return s[k].slice(a, z + 2);
}
function ex(k, n, b = 1, a = 5) {
	const lines = s[k].split('\n');
	let count = 0;
	for (let i = 0; i < lines.length; i++)
		if (lines[i].includes(n)) {
			count++;
			console.log(files[k] + ':' + (i + 1));
			for (let j = Math.max(0, i - b); j <= Math.min(lines.length - 1, i + a); j++)
				console.log(`${j + 1}: ${lines[j]}`);
		}
	assert(count > 0, 'excerpt nonvacuous ' + n);
}
console.log(
	'PROVENANCE: Node22 source assertions and retained source excerpts only. No AHK/Windows/UIA/clipboard/keyboard/menu execution, no JS port of business behavior. Native source projections in report require Windows receiving.'
);
for (const [k, p] of Object.entries(files))
	console.log('sha256 ' + crypto.createHash('sha256').update(s[k]).digest('hex') + ' ' + p);
const add = body('menu', '_WS_MenuAddCustom'),
	active = body('config', '_WS_BuildActivePairs'),
	wrap = body('layout', 'WrapTextIfSelected');
assert(add.includes('WrapSymbols_AddCustom(LeftChar, RightChar)'));
assert(
	body('config', 'WrapSymbols_AddCustom').includes(
		'_WS_BuildAddCustomCandidate.Bind(LeftChar, RightChar)'
	)
);
assert(active.includes('Active[L] := Pair'));
assert(active.indexOf('for Pair in Custom') > active.indexOf('for Pair in _WS_BUILTIN_PAIRS'));
assert(s.layout.includes('Hotkey("SC138 & SC017", _RollHashtagQuoteHandler, "I2")'));
assert(body('layout', 'HashtagOrQuote').includes('WrapTextIfSelected("#", "#", "#")'));
assert(wrap.includes('WrapSymbols_IsEnabled(LeftSymbol)'));
assert(wrap.includes('SendInstant(LeftSymbol Selection RightSymbol)'));
assert(!wrap.includes('WrapSymbols_GetActivePairs'));
console.log(
	'WSW-001 source contract: accepted custom pair overrides active mapping but concrete registered remap caller uses retained built-in args and wrapper never reads current pair.'
);
ex('menu', '_WS_MenuAddCustom() {', 0, 29);
ex('menu', 'Committed := WrapSymbols_AddCustom', 0, 3);
ex('config', 'WrapSymbols_AddCustom(LeftChar', 0, 12);
ex('config', 'for Pair in Custom {', 0, 13);
ex('layout', 'Hotkey("SC138 & SC017"', 1, 2);
ex('layout', '_RollHashtagQuoteEmit() {', 0, 7);
ex('layout', 'WrapTextIfSelected("#",', 2, 3);
ex('layout', 'if (WrapEnabled and WrapSymbols_IsEnabled', 2, 2);
ex('layout', 'if !SendInstant(LeftSymbol Selection RightSymbol)', 2, 7);
ex('send', 'SendInput(Prefix . "^v")', 2, 4);
assert(s.worker.includes('global UIASW_MAX_TEXT_CHARS := 8192'));
assert(body('owner', 'UIASW_Request').includes('UIASW_MAX_TEXT_CHARS'));
const handler = body('worker', 'UIASW_WorkerHandleRequest');
assert(handler.includes('Body := Ranges[1].GetText(MaxTextChars)'));
assert(handler.includes('Status := "ok"'));
assert(!/truncat|oversize|overflow|complete/i.test(handler));
assert(body('layout', '_UIA_OnSelectionWorkerTerminal').includes('Text: PublishableText'));
assert(body('owner', 'UIASW_ConsumeSelectionSnapshot').includes('return Snapshot.Text'));
console.log(
	'WSW-002 source contract: worker requests <=8192, treats nonempty bounded text as ok without completeness status, snapshot consumer returns unchanged text and whole-selection wrapper uses it.'
);
ex('worker', 'global UIASW_MAX_TEXT_CHARS :=', 0, 6);
ex('owner', 'UIASW_Request(Context', 0, 4);
ex('worker', 'Body := Ranges[1].GetText', 5, 8);
ex('layout', 'PublishableText := CandidateText', 3, 2);
ex('layout', 'Text: PublishableText', 2, 9);
ex('owner', 'return Snapshot.Text', 5, 2);
ex('vendor', 'GetText(maxLength :=', 1, 4);
const catalogue = JSON.parse(s.catalogue);
const pairs = catalogue.groups.flatMap((g) => g.pairs);
assert(pairs.length >= 30);
console.log(
	'Catalogue floor: ' +
		pairs.length +
		' ordered pairs. No arbitrary native selection text or clipboard read.'
);
console.log('PASS: 2 nonvacuous source findings; native Windows execution count=0.');
