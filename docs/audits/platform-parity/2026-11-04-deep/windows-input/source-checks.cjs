'use strict';
// Audit source assertions only. Does NOT execute AHK or simulate native hooks.
const fs = require('fs'),
	assert = require('assert'),
	path = require('path');
const root = '/workspace/ergopti/static/ergopti_plus/windows';
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8').replace(/^\uFEFF/, '');
const section = (s, start, end) => {
	const a = s.indexOf(start);
	assert(a >= 0, start);
	const b = s.indexOf(end, a + start.length);
	assert(b > a, end);
	return s.slice(a, b);
};
const lalt = read('platform/remap/lalt.ahk');
const tab = section(lalt, '#HotIf TapHoldTapAction(TapHold, "left_alt") == "tab"', '; RCtrl+LAlt');
assert(!tab.split('\n')[0].includes('TapHoldHoldLayer'));
assert(tab.includes('TapHoldOwnImmediateLayer('));
const writer = read('platform/remap/tap_hold_writer.ahk');
const hold = section(
	writer,
	'_TH_BuildHoldCandidate(KeyId, Kind, Id, Candidate) {',
	'_TH_BuildNativeCandidate'
);
assert(hold.includes('Entry.Delete("hold_layer")') && hold.includes('Kind == "none"'));
assert(lalt.includes('TapHoldHoldModifier(TapHold, "left_alt") != "" and not LayerEnabled'));
console.log(
	'WI-001 SOURCE CONFIRMED: valid None hold removes hold_layer, but tab-only LAlt criterion still unconditionally enters OwnImmediateLayer'
);
const manager = read('ui/layout_manager/init.ahk'),
	composer = read('ui/layout_manager/composer.ahk');
assert(
	manager.includes('return Receipt["status"] == "pending" || Receipt["status"] == "committed"')
);
const use = section(composer, 'if Use && !Selected {', '\n\tif Selected {');
assert(
	use.includes('Deps["select"].Call(Id)') &&
		use.includes('_LayoutComposer_Report(Deps, Action, true, "", "", true)')
);
assert(!use.includes('after') && !use.includes('Reloaded'));
const scope = read('infra/config_scope.ahk');
assert(
	scope.includes('Receipt["status"] := "pending"') &&
		scope.includes('ReloadFn.Call((*) => Receipt["status"] := "committed", Bundle, Refused)')
);
assert(composer.includes('Deps["after"].Call(Id, "install", Reloaded)'));
console.log(
	'WI-002 SOURCE CONFIRMED: unselected Save-and-use publishes used=true after a pending launch receipt, without terminal callback'
);
const kle = read('modules/keymap/keylayout/keylayout_emulation.ahk'),
	lifecycle = read('infra/lifecycle.ahk');
assert(kle.includes('Step := KeylayoutEmulation_StepReplayRoute(Recipe, KLE_State)'));
assert(
	!lifecycle.includes('KeylayoutEmulation_ResetDeadKey') &&
		!lifecycle.includes('KeylayoutEmulation_Unload') &&
		!lifecycle.includes('KLE_State')
);
const resetKeys = kle.match(/global KLE_DEAD_RESET_KEYS := \[[\s\S]*?\]/)[0];
assert(!resetKeys.includes('LButton'));
console.log(
	'OI-001 OBSERVED (policy unresolved): registry composition reads retained KLE_State; suspend lifecycle has no reset/unload and tray mouse is outside reset keys'
);
const combos = read('infra/key_combinations.ahk');
const tick = section(combos, 'KeyCombinationChordTick(Ports := 0) {', '; Runs the look');
const flush = section(combos, '_KeyCombinationChordFlush(Ports) {', '; Sends one catalogue key');
const send = section(
	combos,
	'_KeyCombinationChordSendKey(KeyId, Held, Ports) {',
	'; Sends the queued keys'
);
const drain = section(combos, 'KeyCombinationChordDrain(Ports := 0) {', '; One look at the wait');
assert(tick.includes('if (A_IsSuspended ||') && tick.includes('_KeyCombinationChordFlush(Ports)'));
assert(flush.includes('_KeyCombinationChordSendKey(') && !flush.includes('A_IsSuspended'));
assert(send.includes('Ports["send"].Call(') && !send.includes('A_IsSuspended'));
assert(drain.includes('Ports["send"].Call(') && !drain.includes('A_IsSuspended'));
assert(combos.includes('"send", (Keys) => SendEvent(Keys)'));
console.log(
	'OI-002 OBSERVED (custody rationale): suspend tick flushes waiting chord into raw SendEvent; drain also has no suspend admission'
);
console.log(
	'2 actionable source paths and 2 observations asserted. No AHK code/native scenario executed.'
);
