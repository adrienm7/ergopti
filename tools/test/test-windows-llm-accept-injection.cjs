// tools/test/test-windows-llm-accept-injection.cjs

/**
 * ==============================================================================
 * MODULE: Windows Accepted-Prediction Injection Gate
 * DESCRIPTION:
 * The Windows driver types an accepted AI prediction through TextSend, which
 * only the AHK suite can execute, on Windows CI. This gate checks from the
 * sources, anywhere, what makes that output exact (llm-accept-injects-exact-text):
 *
 * 1. Every TextSender emission goes through _TextSenderAtSendLevel, the one
 *    owner of the emission SendLevel: no send primitive is called outside it,
 *    and it restores the caller's level in a finally.
 * 2. TextSend types a direct text as one Text-mode SendInput batch, never
 *    character by character nor through a keyboard-layout lookup.
 * 3. Both acceptance primitives end in the dispatch that hands the accepted
 *    text itself to LLM_Bridge_OnAccept, which hands it to TextSend.
 * 4. The AHK regression test is registered in run_all.ahk.
 *
 * ROOT CAUSE ENCODED:
 * The physical Tab accepts from its #InputLevel 2 hotkey thread. TextSend's
 * atomic outputs called their send primitive directly, so the prediction left
 * at SendLevel 2, as input every hook below level 2 takes for typing, while
 * every other TextSender emission left at TEXT_SENDER_SEND_LEVEL.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WIN = path.join(ROOT, 'static', 'ergopti_plus', 'windows');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const read = (rel) => fs.readFileSync(path.join(WIN, rel), 'utf8').replace(/^﻿/, '');

/**
 * Removes full-line and trailing AHK comments, keeping line positions.
 * @param {string} source AHK source text.
 * @returns {string} Source without comments.
 */
const stripComments = (source) =>
	source
		.split('\n')
		.map((line) => (/^\s*;/.test(line) ? '' : line.replace(/\s+;.*$/, '')))
		.join('\n');

/**
 * Returns the body of an AHK function declared at column 0, its signature
 * possibly continued on the following lines.
 * @param {string} source AHK source text.
 * @param {string} name Function name.
 * @returns {string} Body text, "" when absent.
 */
const bodyOf = (source, name) => {
	const start = source.search(new RegExp(`^${name}\\(`, 'm'));
	if (start < 0) return '';
	const open = source.slice(start).search(/\)\s*\{[ \t]*$/m);
	if (open < 0) return '';
	const end = source.indexOf('\n}', start + open);
	return end < 0 ? '' : source.slice(start, end);
};

// 1. One owner of the emission SendLevel.
const sender = stripComments(read('adapters/text_sender.ahk'));
const owner = bodyOf(sender, '_TextSenderAtSendLevel');
check(owner !== '', 'adapters/text_sender.ahk must define _TextSenderAtSendLevel');
const setAt = owner.indexOf('SendLevel(TEXT_SENDER_SEND_LEVEL)');
const callAt = owner.indexOf('SendFn.Call()', setAt);
const restoreAt = owner.indexOf('SendLevel(PreviousSendLevel)', callAt);
check(
	setAt > 0 &&
		callAt > setAt &&
		restoreAt > callAt &&
		/finally/.test(owner.slice(callAt, restoreAt)),
	'_TextSenderAtSendLevel must set TEXT_SENDER_SEND_LEVEL, run the emission, and restore the caller level in a finally'
);
check(
	(sender.match(/SendLevel\(TEXT_SENDER_SEND_LEVEL\)/g) || []).length === 1,
	'text_sender.ahk must set TEXT_SENDER_SEND_LEVEL in _TextSenderAtSendLevel only'
);

// Every call of a send primitive, outside _TextSenderAtSendLevel itself, sits
// in the statement that hands it to _TextSenderAtSendLevel.
const lines = sender.split('\n');
const ownerStart = lines.findIndex((line) => /^_TextSenderAtSendLevel\(/.test(line));
const primitiveCall =
	/(_AHK_SendInput|_AHK_SendText|SenderFn)\.Call\(|HS_RunSyntheticInputTransaction\(/;
let primitiveCalls = 0;
lines.forEach((line, index) => {
	if (!primitiveCall.test(line)) return;
	if (index > ownerStart && index < ownerStart + owner.split('\n').length) return;
	primitiveCalls += 1;
	const statement = `${lines[index - 1] || ''}\n${line}`;
	check(
		statement.includes('_TextSenderAtSendLevel('),
		`text_sender.ahk:${index + 1} calls a send primitive outside _TextSenderAtSendLevel: ${line.trim()}`
	);
});
check(
	primitiveCalls >= 2,
	`expected the funnel's declared send and the direct SendText, found ${primitiveCalls} primitive call(s)`
);
check(
	bodyOf(sender, '_TextSenderSendInput').includes(
		'_TextSenderAtSendLevel(_AHK_SendInput.Bind(Keys))'
	),
	'_TextSenderSendInput must emit an undeclared key through _TextSenderAtSendLevel'
);
check(
	bodyOf(sender, '_TextSenderRunAtomicOutput').includes('_TextSenderAtSendLevel(SenderFn)'),
	'_TextSenderRunAtomicOutput must emit through _TextSenderAtSendLevel(SenderFn)'
);

// 2. A direct text is one Text-mode batch.
const textSend = bodyOf(sender, 'TextSend');
check(
	textSend.includes('_AHK_SendInput.Bind(ErasePrefix . "{Text}" . Text)'),
	'TextSend must type a direct atomic text as one Text-mode SendInput batch'
);
check(
	!/VkKeyScan|GetKeySC|GetKeyVK|Loop\s+Parse|StrSplit\(Text/i.test(sender),
	'text_sender.ahk must never map text through the keyboard layout or send it per character'
);

// 3. The accepted text itself reaches TextSend.
const bridge = stripComments(read('modules/keymap/llm_bridge.ahk'));
const dispatch = bodyOf(bridge, '_LLM_Accept_ClaimAndDispatch');
check(
	/LLM_Bridge_OnAccept\(\s*Presented\.Text,/.test(dispatch),
	'_LLM_Accept_ClaimAndDispatch must hand the presented text itself to LLM_Bridge_OnAccept'
);
check(
	/_LLM_Accept_ClaimAndDispatch\(Presented/.test(bodyOf(bridge, 'LLM_Tooltip_TryAcceptTab')) &&
		/_LLM_Accept_ClaimAndDispatch\(Presented/.test(bodyOf(bridge, 'LLM_Tooltip_TryAcceptSlot')),
	'both acceptance primitives must end in _LLM_Accept_ClaimAndDispatch'
);
check(
	/TextSend\(text, _LLM_Bridge_InjectionOptions\(Transaction\)/.test(
		bodyOf(bridge, 'LLM_Bridge_OnAccept')
	),
	'LLM_Bridge_OnAccept must type the accepted text through TextSend'
);

// 4. The behavioural regression runs in the AHK suite.
const testFile = 'tests/unit/test_llm_accept_injects_exact_text.ahk';
check(
	/^#Include unit\/test_llm_accept_injects_exact_text\.ahk\s*$/m.test(read('tests/run_all.ahk')),
	`tests/run_all.ahk must include ${testFile}`
);
check(
	read(testFile).includes('(llm-accept-injects-exact-text)'),
	`${testFile} must carry the llm-accept-injects-exact-text slug`
);

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] Windows accepted-prediction injection: ${checks} check(s) passed.\x1b[0m`
);
