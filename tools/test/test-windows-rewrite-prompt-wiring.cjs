// tools/test/test-windows-rewrite-prompt-wiring.cjs

/**
 * ==============================================================================
 * MODULE: Windows Rewrite Prompt and Prompt Action Wiring Gate
 * DESCRIPTION:
 * The rewrite prompt and the "AI prediction with a chosen prompt" action reach
 * the Windows driver through AutoHotkey ports and wiring that only the AHK suite
 * can execute, and that suite runs on Windows CI only. This gate checks, from
 * the sources, what can be checked anywhere:
 *
 * 1. The two ports (modules/llm/rewrite.ahk, modules/llm/prompt_action.ahk) are
 *    #Included by the driver and by the AHK suite, rewrite.ahk before the parser
 *    that calls it, and their tests are registered in run_all.ahk and replay the
 *    shared corpora.
 * 2. The driver's built-in profile order is exactly the id list of
 *    _shared/modules/llm/profiles.json, since the llm_predict_<id> actions and
 *    the menu are built from it.
 * 3. The parser port carries the rewrite mode of the shared parser and refuses
 *    erasures without the exact deleted text and span; accepting erases in one SendInput
 *    batch as the text, for both the direct and the clipboard sender.
 * 4. The action picker host sends what the page's prompt editor needs.
 * 5. The tone ladder port (modules/llm/tone.ahk) and its actions
 *    (modules/llm/tone_action.ahk) are included before the gesture actions
 *    registered from them, and their test replays the shared tone corpus.
 * 6. The screen reading port (modules/llm/vision.ahk) and its actions
 *    (modules/llm/vision_action.ahk) are included the same way, their test
 *    replays the shared vision corpus, the llm_vision parameter kind is
 *    validated, prompted and sent to the picker, and the capture and request
 *    seams they run through exist.
 * 7. Live mode (modules/llm/prediction_live.ahk) is included by the prediction
 *    engine, its action is registered, the automatic trigger and the hotstring
 *    chain arm its override and pausing ends it; the duplicate menu is retired.
 * 8. "Why this error?" (llm_screen_error) is a screen action drafting
 *    vision.json's error_answers; the selection translation port
 *    (modules/llm/translate.ahk) and its action (translate_action.ahk) are
 *    included after the screen actions whose sender they share, their test
 *    replays the shared translate corpus, the llm_language kind is validated,
 *    prompted and sent to the picker, and an accepted translation is selected
 *    again by the bridge's completion.
 * 9. The AI agent's port (modules/llm/agent.ahk), its connectors and its
 *    actions are included after the translation and before the gesture actions
 *    registered from them, its test replays the shared agent corpus, the
 *    bridge feeds the typing to its automatic mode and runs an accepted
 *    candidate's own handler instead of typing, the tray builds its top-level
 *    submenu, its settings ride the AI menu's persistence, every COM and
 *    process call goes through the adapters and a mail is never sent.
 * 10. The remote formats port (modules/llm/remote_formats.ahk: Backboard and
 *    TypeSafe's decisions) is included before the remote API layer that calls
 *    it, its test replays the shared remote formats corpus, and System 1 has
 *    its Jev transport next to the chat one.
 *
 * ROOT CAUSE ENCODED:
 * A module that no runner includes, or a list restated by hand, fails silently
 * on the platform where nobody can run the suite before CI does.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const WIN = path.join(SP, 'windows');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const read = (rel) => fs.readFileSync(path.join(WIN, rel), 'utf8').replace(/^﻿/, '');

/**
 * Returns the ordered #Include targets of an AHK source.
 * @param {string} source AHK source text.
 * @returns {string[]} Include paths as written, forward slashes.
 */
const includesOf = (source) =>
	[...source.matchAll(/^#Include\s+(\S+)\s*$/gm)].map((m) => m[1].replace(/\\/g, '/'));

/**
 * Returns the body of an AHK function, including continued argument lists.
 * @param {string} source AHK source text.
 * @param {string} name Function name.
 * @returns {string} Body text, "" when absent.
 */
const bodyOf = (source, name) => {
	const start = source.search(
		new RegExp('^PLACEHOLDER\\([\\s\\S]*?\\)\\s*\\{\\s*$'.replace('PLACEHOLDER', name), 'm')
	);
	if (start < 0) return '';
	const end = source.indexOf('\n}', start);
	return end < 0 ? '' : source.slice(start, end);
};

// 1. Includes, order and test registration.
const entry = includesOf(read('ErgoptiPlus.ahk'));
const runAll = includesOf(read('tests/run_all.ahk'));
const bench = includesOf(read('tests/bench_parity_process_prediction.ahk'));
const position = (list, target) => list.indexOf(target);

for (const [label, list, prefix] of [
	['ErgoptiPlus.ahk', entry, ''],
	['tests/run_all.ahk', runAll, '../']
]) {
	const rewrite = position(list, `${prefix}modules/llm/rewrite.ahk`);
	const action = position(list, `${prefix}modules/llm/prompt_action.ahk`);
	check(rewrite >= 0, `${label} must #Include modules/llm/rewrite.ahk`);
	check(action >= 0, `${label} must #Include modules/llm/prompt_action.ahk`);
	check(
		rewrite >= 0 && rewrite < position(list, `${prefix}modules/llm/parser.ahk`),
		`${label} must include rewrite.ahk before parser.ahk, whose rewrite record calls it`
	);
	check(
		rewrite >= 0 && rewrite < position(list, `${prefix}modules/llm/prediction_engine.ahk`),
		`${label} must include rewrite.ahk before the prediction engine`
	);
	const validation = position(list, `${prefix}modules/llm/option_validation.ahk`);
	const gestures = position(list, `${prefix}modules/gestures/init.ahk`);
	check(
		validation >= 0 && gestures > validation,
		`${label} must include option_validation.ahk (LLM_PROFILE_BUILTIN_ORDER) before the gesture actions registered from it`
	);
	const tone = position(list, `${prefix}modules/llm/tone.ahk`);
	const toneAction = position(list, `${prefix}modules/llm/tone_action.ahk`);
	check(
		tone >= 0 && toneAction > tone && gestures > toneAction,
		`${label} must include tone.ahk, then tone_action.ahk, before the gesture actions registered from them`
	);
	const vision = position(list, `${prefix}modules/llm/vision.ahk`);
	const visionAction = position(list, `${prefix}modules/llm/vision_action.ahk`);
	check(
		vision >= 0 && visionAction > vision && gestures > visionAction,
		`${label} must include vision.ahk, then vision_action.ahk, before the gesture actions registered from them`
	);
	const translate = position(list, `${prefix}modules/llm/translate.ahk`);
	const translateAction = position(list, `${prefix}modules/llm/translate_action.ahk`);
	check(
		translate > visionAction && translateAction > translate && gestures > translateAction,
		`${label} must include translate.ahk, then translate_action.ahk, after vision_action.ahk and before the gesture actions`
	);
	const remoteFormats = position(list, `${prefix}modules/llm/remote_formats.ahk`);
	check(
		remoteFormats >= 0 && remoteFormats < position(list, `${prefix}modules/llm/api_remote.ahk`),
		`${label} must include remote_formats.ahk before api_remote.ahk, which builds its requests with it`
	);
	const agent = position(list, `${prefix}modules/llm/agent.ahk`);
	const agentConnectors = position(list, `${prefix}modules/llm/agent_connectors.ahk`);
	const agentAction = position(list, `${prefix}modules/llm/agent_action.ahk`);
	check(
		agent > translateAction &&
			agentConnectors > agent &&
			agentAction > agentConnectors &&
			gestures > agentAction,
		`${label} must include agent.ahk, agent_connectors.ahk, then agent_action.ahk after the translation and before the gesture actions`
	);
}
check(
	includesOf(read('ui/menu/menu_llm/_index.ahk')).includes('menu_agent.ahk') &&
		runAll.includes('../ui/menu/menu_llm/menu_agent.ahk'),
	'the AI agent submenu must be included by the AI menu index and by the AHK suite'
);
check(
	position(bench, '../modules/llm/rewrite.ahk') >= 0 &&
		position(bench, '../modules/llm/rewrite.ahk') < position(bench, '../modules/llm/parser.ahk'),
	'the parity bench must include rewrite.ahk before parser.ahk'
);

const TESTS = {
	'unit/test_llm_rewrite.ahk': 'rewrite_vectors.json',
	'unit/test_llm_prompt_action.ahk': 'llm_prompt_vectors.json',
	'unit/test_llm_prompt_prediction.ahk': 'llm_prompt_prediction',
	'unit/test_llm_parser.ahk': 'process_prediction_vectors.json',
	'unit/test_llm_tone.ahk': 'tone_vectors.json',
	'unit/test_llm_vision.ahk': 'vision_vectors.json',
	'unit/test_llm_translate.ahk': 'translate_vectors.json',
	'unit/test_llm_agent.ahk': 'agent_vectors.json',
	'unit/test_llm_remote_formats.ahk': 'remote_formats_vectors.json',
	'unit/test_llm_live_mode.ahk': 'llm_live_prompt_toggle'
};
for (const [test, needle] of Object.entries(TESTS)) {
	check(runAll.includes(test), `tests/run_all.ahk must #Include ${test}`);
	check(read(`tests/${test}`).includes(needle), `tests/${test} must exercise ${needle}`);
}

// 2. The built-in order is the shared registry's id list.
const profileIds = JSON.parse(
	fs.readFileSync(path.join(SP, '_shared', 'modules', 'llm', 'profiles.json'), 'utf8')
).map((profile) => profile.id);
const validation = read('modules/llm/option_validation.ahk');
const orderBlock =
	(validation.match(/global LLM_PROFILE_BUILTIN_ORDER := \[([\s\S]*?)\]/) || [])[1] || '';
const order = [...orderBlock.matchAll(/"([^"]+)"/g)].map((m) => m[1]);
check(
	JSON.stringify(order) === JSON.stringify(profileIds),
	`LLM_PROFILE_BUILTIN_ORDER ${JSON.stringify(order)} must equal the profiles.json ids ${JSON.stringify(profileIds)}`
);
const actions = read('modules/gestures/actions.ahk');
check(
	/for _PresetProfileId in LLM_PROFILE_BUILTIN_ORDER \{/.test(actions) &&
		actions.includes('GESTURE_ACTIONS["llm_predict_" . _PresetProfileId]'),
	'the llm_predict_<id> actions must be registered from LLM_PROFILE_BUILTIN_ORDER'
);
check(
	actions.includes('"llm_prompt_prediction", {'),
	'llm_prompt_prediction must be a registered action'
);
check(
	/for _ToneActionId, _ToneStep in LLM_ToneActions\(\) \{/.test(actions),
	'the llm_tone_* actions must be registered from LLM_ToneActions'
);
const toneActions = read('modules/llm/tone_action.ahk');
for (const id of [
	'llm_tone_more_formal',
	'llm_tone_more_familiar',
	'llm_tone_more_formal_cycle',
	'llm_tone_more_familiar_cycle'
]) {
	check(toneActions.includes(`"${id}", {`), `LLM_ToneActions must declare ${id}`);
}
const menuProfiles = read('ui/menu/menu_llm/menu_profiles.ahk');
check(
	!/for id in \["raw"/.test(menuProfiles) && !/Map\("raw", true/.test(menuProfiles),
	'the profile menu must list the built-ins from LLM_PROFILE_BUILTIN_ORDER, not a hand-written copy'
);

// 3. Parser rewrite mode and the erase step.
const parser = read('modules/llm/parser.ahk');
const impl = bodyOf(parser, '_LLM_Parser_ProcessPredictionImpl');
check(impl !== '', 'parser.ahk must define _LLM_Parser_ProcessPredictionImpl');
for (const [needle, why] of [
	['is_rewrite := InStr(block, "REWRITE:", true) > 0', 'detects a rewrite from the normalised tag'],
	[
		'while (!is_rewrite and ops.Length > 0 and ops[1]["type"] = "del")',
		"keeps a rewrite's leading deletions"
	],
	['if (first_change_idx = -1 and is_rewrite)', 'offers nothing for an unchanged rewrite'],
	[
		'max_allowed_dels := is_rewrite ? StrLen(orig_context)',
		"bounds a rewrite's erasure by its span"
	],
	['if (only_equals and !is_rewrite)', 'skips the orphaned-gray guard for a rewrite'],
	['_LLM_Parser_ErasingRecord(', 'records the exact text a correction or rewrite erases']
]) {
	check(impl.includes(needle), `_LLM_Parser_ProcessPredictionImpl ${why}: ${needle}`);
}
check(
	bodyOf(parser, '_LLM_Parser_CleanModelOutput').includes('"i)\\[REWRITE\\]"'),
	'the output cleaner must normalise the bracketed rewrite tag'
);
const injectable = bodyOf(parser, '_LLM_Parser_IsPhysicallyInjectable');
const namedErasure =
	/if \(pred\.Get\("deleted_text", ""\) != "" and pred\.Get\("span", ""\) != ""\)\s+return true/;
check(
	namedErasure.test(injectable) && injectable.includes('return false'),
	'an erase-bearing prediction must name both its exact deleted text and original span'
);
for (const field of ['deleted_text', 'span']) {
	check(
		!namedErasure.test(injectable.replace(`pred.Get("${field}", "") != ""`, 'true')),
		`erasure admission must reject a missing ${field} guard`
	);
}
const erasingRecord = bodyOf(parser, '_LLM_Parser_ErasingRecord');
for (const field of [
	'"deleted_text", DeletedText',
	'"span", Span',
	'"deletes", LLM_Rewrite_CodepointLength(DeletedText)'
]) {
	check(erasingRecord.includes(field), `the parser must record the exact erasure: ${field}`);
}

const sender = read('adapters/text_sender.ahk');
check(
	bodyOf(sender, 'TextSend').includes('_AHK_SendInput.Bind(ErasePrefix . "{Text}" . Text)'),
	'the direct sender must send the erasure and the text as one SendInput batch'
);
check(
	bodyOf(sender, '_TextSendClipboard').includes(
		'_AHK_SendInput.Bind(_TextSenderErasePrefix(Opts) . "^v")'
	),
	'the clipboard sender must send the erasure and the paste as one SendInput batch'
);
const bridge = read('modules/keymap/llm_bridge.ahk');
check(
	bodyOf(bridge, '_LLM_Bridge_InjectionOptions').includes('"erase_before", Transaction.Deletes'),
	'the accept transaction must hand its erasure to the sender'
);
check(
	bodyOf(bridge, '_LLM_Bridge_CommitInjectedText').includes(
		'_LLM_Bridge_ApplyBufferEdit(StrLen(Transaction.DeletedText), Transaction.Text)'
	),
	'the buffer must mirror the erasure and the insert in the output transaction'
);

// 4. The picker host feeds the page's prompt editor.
const picker = read('ui/action_picker_webview.ahk');
for (const field of [
	'promptChoices',
	'defaultCount',
	'editCurrentLabel',
	'promptLabel',
	'countLabel',
	'countDefault'
]) {
	check(picker.includes(`"${field}"`), `the Windows action picker host must send ${field}`);
}
check(
	picker.includes('_ActPickWeb_Kv("llm_prompt"'),
	'the picker host must send the llm_prompt prompt and refusal'
);
check(
	/Parameter := \(Kind != ""\)/.test(picker),
	'every parameterized action must carry its kind and value'
);

// 6. Screen reading: actions, parameter kind, picker payload and seams.
check(
	/for _VisionActionId, _VisionKind in LLM_VisionActions\(\) \{/.test(actions),
	'the llm_screen_* actions must be registered from LLM_VisionActions'
);
const visionActions = read('modules/llm/vision_action.ahk');
for (const id of ['llm_screen_region', 'llm_screen_full']) {
	check(visionActions.includes(`"${id}", "`), `LLM_VisionActions must declare ${id}`);
}
const gestureConfig = read('modules/gestures/config.ahk');
for (const [needle, why] of [
	['if (Spec = "llm_vision") {', 'validates the llm_vision kind'],
	['t("dialog.gestures.param_err_llm_vision")', "refuses with the kind's error text"],
	['case "llm_vision":', 'prompts for the llm_vision kind'],
	['LLM_Vision_BackendChoicesText()', 'lists the vision backends in the prompt']
]) {
	check(gestureConfig.includes(needle), `modules/gestures/config.ahk ${why}: ${needle}`);
}
for (const field of [
	'visionChoices',
	'visionProviderLabel',
	'visionModelLabel',
	'visionModelDefault',
	'visionModelRequired',
	'defaultModel'
]) {
	check(picker.includes(`"${field}"`), `the Windows action picker host must send ${field}`);
}
check(
	picker.includes('_ActPickWeb_Kv("llm_vision"'),
	'the picker host must send the llm_vision prompt and refusal'
);
const remote = read('modules/llm/api_remote.ahk');
check(
	bodyOf(remote, 'LLM_RemotePostBody_Async').includes(
		'_LLMRemote_DispatchCurl(req_id, Resolved, Url, Payload'
	),
	'a caller-written remote body must go through the curl transport'
);
const streaming = read('modules/llm/api_ollama/ollama_streaming.ahk');
check(
	bodyOf(streaming, '_LLM_Ollama_DispatchAsync').includes('job.Get("payload", "")'),
	'the local dispatcher must send a caller-written chat body as it is'
);
check(
	/^LLM_OllamaChat_Async\(payload, on_success, on_fail\) \{$/m.test(streaming),
	'the local server must accept a caller-written chat body'
);
const screenshots = read('modules/gestures/screenshots.ahk');
check(
	bodyOf(screenshots, '_GestureScreenshotDirectScript').includes(
		'_GestureScreenshotDownscaleScript("$bmp", MaxEdge)'
	) &&
		bodyOf(screenshots, '_GestureScreenshotRegionSaveScript').includes(
			'_GestureScreenshotDownscaleScript("$img", MaxEdge)'
		),
	'both capture scripts must shrink the image to the requested longest edge'
);
check(
	bodyOf(screenshots, 'GestureRegionCaptureFinish').includes(
		'_GestureRegionNotify(State.Get("callback", 0)'
	),
	'a region capture must report its end to the owner that asked for it'
);

// 7. Live mode: one owner, the automatic trigger's override, pause and menu.
check(
	includesOf(read('modules/llm/prediction_engine.ahk')).includes('prediction_live.ahk'),
	'the prediction engine must include prediction_live.ahk, the owner of live mode'
);
check(
	actions.includes('"llm_live_prompt_toggle", {') &&
		bodyOf(actions, 'GestureLivePromptToggle').includes('LLM_Menu_ToggleLiveMode('),
	'llm_live_prompt_toggle must be a registered action running the live toggle'
);
const keystrokes = read('modules/llm/prediction_keylogger.ahk');
// StartTimer's signature spans two lines, which bodyOf does not follow.
const bodyFrom = (source, name) => {
	const start = source.search(new RegExp(`^${name}\\(`, 'm'));
	const end = start < 0 ? -1 : source.indexOf('\n}', start);
	return end < 0 ? '' : source.slice(start, end);
};
for (const name of ['LLM_Engine_OnKeystroke', 'LLM_Engine_StartTimer']) {
	const body = bodyFrom(keystrokes, name);
	check(
		body.includes('LLM_Engine_LiveOverride()') && body.includes('LLM_Engine_LiveDebounceMs()'),
		`${name} must arm live mode's override and debounce`
	);
}
check(
	bodyOf(read('infra/lifecycle.ahk'), 'Ergopti_OnSuspendEnter').includes('"llm-live-mode"'),
	'pausing must turn live mode off'
);
const menuEmit = bodyOf(read('ui/menu/menu_llm/menu_main.ahk'), '_LLM_Menu_EmitRow');
const menuSettings = read('ui/menu/menu_llm/menu_settings.ahk');
check(
	menuEmit !== '' &&
		!menuEmit.includes('case "llm_live_mode":') &&
		!menuEmit.includes('Map("llm_live_mode", LLM_Menu_BuildLiveModeMenu)'),
	'the genuine AI menu emitter must not reintroduce a duplicate live selector'
);
for (const name of [
	'LLM_Menu_BuildLiveModeMenu',
	'_LLM_Menu_LiveModeRows',
	'_LLM_Menu_MakeLiveModeHandler'
]) {
	check(
		bodyOf(menuSettings, name) === '',
		`the unreachable live menu provider ${name} must be retired`
	);
}
const liveStart = bodyOf(menuSettings, 'LLM_Menu_StartLiveMode');
const liveStop = bodyOf(menuSettings, 'LLM_Menu_StopLiveMode');
check(
	liveStart !== '' &&
		liveStart.includes('LLM_Menu_ManualPredictionRefusal(') &&
		liveStart.includes('LLM_Engine_LiveStart(') &&
		liveStart.includes('return false'),
	'the retained shortcut start must still validate admission before its actual engine owner'
);
check(
	liveStop !== '' &&
		liveStop.includes('if !LLM_Engine_LiveStop(') &&
		liveStop.indexOf('return false') < liveStop.indexOf('_LLM_Menu_ShowNotice('),
	'the retained stop must preserve an inactive engine refusal before any success notice'
);
check(
	bodyOf(
		read('infra/hotstrings/hotstring_dispatch.ahk'),
		'_HSE_MirrorCanonicalEffectToLlm'
	).includes('LLM_Bridge_ReissueLiveAfterExpansion()'),
	'a hotstring expansion must re-issue the live request on the expanded text'
);

// 8. "Why this error?" and the selection translation.
check(
	visionActions.includes('"llm_screen_error", "region"') &&
		bodyOf(visionActions, 'LLM_Vision_AnswersKey').includes('"error_answers"'),
	'llm_screen_error must be a region screen action drafting error_answers'
);
check(
	bodyOf(actions, 'GestureScreenVision').includes('LLM_Vision_AnswersKey(ActionId)'),
	'every screen action must run its own answer list'
);
check(
	bodyOf(visionActions, '_LLM_Vision_NextAnswer').includes('Flow["prompts"]') &&
		!visionActions.includes('Config["answers"]'),
	'the screen flow must draft the answer list it was started with, never a fixed one'
);
check(
	bodyOf(read('modules/llm/vision.ahk'), '_LLM_Vision_ValidateConfig').includes('"error_answers"'),
	'vision.json must be refused without its error answers'
);
check(
	actions.includes('"llm_translate_selection", {') &&
		bodyOf(actions, 'GestureTranslateSelection').includes('LLM_Translate_Trigger('),
	'llm_translate_selection must be a registered action running the translation'
);
const translateAction = read('modules/llm/translate_action.ahk');
check(
	bodyOf(translateAction, 'LLM_Translate_Trigger').includes('LLM_Menu_ManualPredictionRefusal(') &&
		bodyOf(translateAction, 'LLM_Translate_Trigger').includes('LLM_SelectionReader()'),
	'the translation must apply the manual-prediction refusals and read the selection like the tone ladder'
);
check(
	bodyOf(translateAction, '_LLM_Translate_OnSelection').includes('LLM_Vision_SendText('),
	"the translation must ask through the screen answers' sender"
);
check(
	bodyOf(translateAction, '_LLM_Translate_Show').includes('SelectAfterAccept: true'),
	'the translation candidate must ask to stay selected once accepted'
);
check(
	bodyOf(bridge, '_LLM_Bridge_OnInjectComplete').includes(
		'_LLM_Bridge_SelectAcceptedText(Transaction)'
	) && bodyOf(bridge, '_LLM_Bridge_SelectAcceptedText').includes('TextSelectBack('),
	'a successful acceptance must select again a slot that asks for it'
);
for (const [needle, why] of [
	['if (Spec = "llm_language") {', 'validates the llm_language kind'],
	['t("dialog.gestures.param_err_llm_language")', "refuses with the kind's error text"],
	['case "llm_language":', 'prompts for the llm_language kind'],
	['LLM_Translate_Config()["max_language_bytes"]', 'declares the free-language input limit']
]) {
	check(gestureConfig.includes(needle), `modules/gestures/config.ahk ${why}: ${needle}`);
}
/** Receives the nonempty native language candidate path, never an optional empty helper. */
function languageInputWiring(source) {
	const prompt = bodyOf(source, 'GesturePromptActionParameter');
	if (prompt === '') return false;
	const input = prompt.indexOf('Result := Ui_InputBox(Prompt, Title, Size, Existing)');
	const cancel = prompt.indexOf('if (Result.Result != "OK")');
	const blank = prompt.indexOf('if (Spec == "llm_language" && Value == "")');
	const validate = prompt.indexOf(
		'if GestureValidateActionParameter(ActionName, Value, &ErrorText)'
	);
	const candidate = prompt.indexOf(
		'"key", GestureActionParameterKey(BindingId, ActionName)',
		validate
	);
	return (
		input >= 0 &&
		cancel > input &&
		blank > cancel &&
		validate > blank &&
		candidate > validate &&
		/if \(Result\.Result != "OK"\)\s+return false/.test(prompt) &&
		/if \(Spec == "llm_language" && Value == ""\)\s+return false/.test(prompt) &&
		!prompt.includes('LLM_Translate_ChoicesText()')
	);
}
check(
	languageInputWiring(gestureConfig),
	'the native language InputBox must refuse cancel/blank and build only a validated per-binding candidate'
);
for (const [needle, label] of [
	['if (Result.Result != "OK")', 'cancel'],
	['if (Spec == "llm_language" && Value == "")', 'blank'],
	['if GestureValidateActionParameter(ActionName, Value, &ErrorText)', 'typed validation'],
	['"key", GestureActionParameterKey(BindingId, ActionName)', 'binding identity']
]) {
	const prompt = bodyOf(gestureConfig, 'GesturePromptActionParameter');
	check(
		prompt !== '' &&
			prompt.includes(needle) &&
			!languageInputWiring(gestureConfig.replaceAll(needle, 'REMOVED_REQUIRED_BOUNDARY')),
		`the native input guard must detect omission of ${label}`
	);
}
check(
	!languageInputWiring(''),
	'a missing native language owner can never satisfy the input guard'
);
for (const field of ['languageChoices', 'languageLabel']) {
	check(picker.includes(`"${field}"`), `the Windows action picker host must send ${field}`);
}
check(
	picker.includes('_ActPickWeb_Kv("llm_language"') &&
		bodyOf(picker, '_ActPickWeb_LanguageChoicesJson').includes('LLM_Translate_ShippedChoices()'),
	'the picker host must send the llm_language prompt, refusal and the shipped choices'
);

// 9. The AI agent.
for (const id of ['llm_agent_selection', 'llm_agent_command', 'llm_agent_auto_toggle']) {
	check(actions.includes(`"${id}", {`), `${id} must be a registered gesture action`);
}
const agentPort = read('modules/llm/agent.ahk');
const agentAction = read('modules/llm/agent_action.ahk');
const agentConnectors = read('modules/llm/agent_connectors.ahk');
const agentMenu = read('ui/menu/menu_llm/menu_agent.ahk');
for (const name of [
	'LLM_Agent_System1Prompt',
	'LLM_Agent_System2Prompt',
	'LLM_Agent_ResolveModel',
	'LLM_Agent_ParseSystem1',
	'LLM_Agent_ParseJev',
	'LLM_Agent_JevQuestions',
	'LLM_Agent_ParseActions',
	'LLM_Agent_Label',
	'LLM_Agent_Ics',
	'LLM_Agent_Mailto',
	'LLM_Agent_Learn'
]) {
	check(bodyOf(agentPort, name) !== '', `agent.ahk must port ${name}`);
}
const typingBodies = Object.fromEntries(
	[
		'LLM_Bridge_OnChar',
		'LLM_Bridge_OnBackspace',
		'_LLM_Bridge_NotifyChar',
		'LLM_Bridge_FeedCharForPrefix',
		'_LLM_Bridge_SchedulePrefixObserver',
		'_LLM_Bridge_RunPrefixObserver'
	].map((name) => [name, bodyOf(bridge, name)])
);
for (const [name, body] of Object.entries(typingBodies)) {
	check(body !== '', `the typing observer's declared owner ${name} must exist`);
}
check(
	bridge.includes('Handler := _LLM_Bridge_AcceptedSlotHandler(Transaction)') &&
		bodyOf(bridge, '_LLM_Bridge_AcceptedSlotHandler').includes('"OnAccept"'),
	'an accepted candidate with its own handler must run it instead of typing'
);
check(
	bodyOf(agentAction, '_LLM_Agent_Show').includes('OnAccept: _LLM_Agent_Accept.Bind(Flow, Action)'),
	'each agent candidate must carry its own accept handler'
);
check(
	bodyOf(agentAction, '_LLM_Agent_ManualRefusal').includes('LLM_Menu_ManualPredictionRefusal(') &&
		bodyOf(agentAction, 'LLM_Agent_TriggerSelection').includes('LLM_SelectionReader()'),
	'the agent must apply the manual-prediction refusals and read the selection like the tone ladder'
);
check(
	(agentAction.match(/_LLM_Agent_Chat\(/g) || []).length === 3 &&
		bodyOf(agentAction, 'LLM_Agent_System1Request').includes('_LLM_Agent_Chat(') &&
		bodyOf(agentAction, 'LLM_Agent_System2Request').includes('_LLM_Agent_Chat('),
	"System 1 and System 2 must each have one transport function, the only callers of the agent's chat sender"
);
check(
	bodyOf(agentAction, '_LLM_Agent_OnPause').includes('_LLM_Agent_Auto["triaged"].Has(Sentence)') &&
		bodyOf(agentAction, '_LLM_Agent_OnPause').includes('LLM_Engine_LiveIsActive()') &&
		bodyOf(agentAction, '_LLM_Agent_OnPause').includes('SFD_IsSecureField()'),
	'the automatic mode must skip a triaged sentence, live mode and secure fields'
);
check(
	bodyOf(agentAction, 'LLM_Agent_System1Request').includes('_LLM_Agent_Decide(') &&
		bodyOf(agentAction, '_LLM_Agent_Decide').includes('LLM_RemoteDecisions_Async(') &&
		bodyOf(agentAction, '_LLM_Agent_Decide').includes('LLM_RemoteBackboard_Async('),
	'System 1 must ask Jev through a decisions provider or Backboard next to its chat transport'
);
check(
	bodyOf(agentAction, '_LLM_Agent_LearningState').includes('ST_Get') &&
		bodyOf(agentAction, '_LLM_Agent_SaveLearning').includes('ST_Set'),
	'the learned thresholds must live in the local state store, not config.toml'
);
for (const [source, label] of [
	[agentAction, 'agent_action.ahk'],
	[agentConnectors, 'agent_connectors.ahk'],
	[agentMenu, 'menu_agent.ahk']
]) {
	check(
		!/\bComObject\(|\bRun\(|\bRunWait\(|\bFileOpen\(|\bFileAppend\(|\bFileDelete\(|\bDllCall\(/.test(
			source
		),
		`${label} must reach COM, processes and files through windows/adapters`
	);
}
check(
	!/\.Send\(/.test(agentConnectors) &&
		bodyOf(agentConnectors, '_LLM_AgentConnector_Mail').includes('Item.Display()'),
	'a mail must only ever be displayed as a draft, never sent'
);
check(
	read('ui/menu/menu_init.ahk').includes('"agent",           _MI_StageAgent') &&
		bodyOf(agentMenu, 'LLM_Agent_MenuBuild').includes('MenuRenderer_Build("agent_menu"'),
	'the tray must build the top-level agent row from the manifest agent_menu'
);
check(
	bodyOf(read('ui/menu/menu_llm/persist.ahk'), '_LLM_Menu_SyncToFeatures').includes(
		'LLM_AGENT_SETTING_KEYS'
	) &&
		bodyOf(read('ui/menu/menu_llm/persist.ahk'), 'LLM_Menu_BuildSavedOpts').includes(
			'LLM_AGENT_SETTING_KEYS'
		),
	'the agent settings must ride the AI menu persistence both ways'
);

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Windows rewrite prompt wiring:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] Windows rewrite prompt and prompt action wiring (${checks} checks).\x1b[0m`
);
