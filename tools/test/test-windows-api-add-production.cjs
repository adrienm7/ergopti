// tools/test/test-windows-api-add-production.cjs

/**
 * ==============================================================================
 * MODULE: Windows API Add Production Source Controls
 * DESCRIPTION:
 * Checks that the native form retains its original source through every modal
 * and the existing joint WAL, with meaningful withdrawal controls. These source
 * controls do not execute AutoHotkey, native dialogs, DPAPI or Windows networking.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../..');
const windows = path.join(root, 'static/ergopti_plus/windows');
const menu = fs.readFileSync(path.join(windows, 'ui/menu/menu_llm/menu_api_entries.ahk'), 'utf8');
const remote = fs.readFileSync(path.join(windows, 'modules/llm/api_remote.ahk'), 'utf8');
const suite = fs.readFileSync(
	path.join(windows, 'tests/unit/modules/llm/api/test_llm_api_add_production.ahk'),
	'utf8'
);

function subject(source) {
	const first = source.indexOf('_LLM_Menu_PromptApiEntry(EditId, Port := 0) {');
	const last = source.indexOf(
		'_LLM_Menu_UpsertApiEntryCandidate(Candidate, NewEntry, EditId) {',
		first
	);
	assert(first >= 0 && last > first, 'the complete actual form must be present');
	return source.slice(first, last);
}

function admission(source) {
	const form = subject(source);
	assert(
		form.includes('Options.Get("input", Ui_InputBox)'),
		'native dialog is the default input owner'
	);
	assert(form.includes('Owner := LLM_Menu_ApiPrivateSourceOwner(SourceOptions)'));
	const capture = form.indexOf('Receipt := Owner.Capture()');
	const inputs = [...form.matchAll(/ib := InputFn\.Call\(/g)].map((match) => match.index);
	const fences = [...form.matchAll(/if !Owner\.Current\(Receipt\)/g)].map((match) => match.index);
	assert.equal(inputs.length, 4, 'provider, URL, secret and model retain the actual modal order');
	assert.equal(fences.length, 4, 'each returned modal answer retains its originating source');
	assert(capture >= 0 && capture < inputs[0]);
	for (let i = 0; i < inputs.length; i += 1) {
		assert(inputs[i] < fences[i]);
		if (i + 1 < inputs.length) assert(fences[i] < inputs[i + 1]);
	}
	const commit = form.indexOf('Committed := LLM_Menu_CommitApiEntriesMutation(');
	assert(commit > fences[3], 'the existing transaction receives only a current completed form');
	assert(form.includes('Receipt, Owner, (*) => true)'), 'the WAL keeps the exact old source owner');
	assert(form.includes('if !((Committed is Integer) && Committed == 1)'));
	assert(!form.includes('_LLM_Menu_PersistApiEntries('), 'the form cannot bypass the joint writer');
	assert(form.indexOf('_LLM_Menu_AskTestNewApiEntry()') > commit);
	assert(
		form.includes('if (Ask is Integer) && Ask == 1'),
		'only an exact affirmative answer starts a probe'
	);
	assert(form.indexOf('ReadyFn.Call(new_entry,') > commit);
	assert(form.includes('new_token := ib.Value'), 'credentials retain exact surrounding bytes');
	assert(
		form.includes(
			'LocalServerAuthEntryTokenAllowed(provider_id, "", new_url, LLM_LOCAL_API_SERVERS)'
		)
	);
}

admission(menu);
let refusals = 0;
const form = subject(menu);
const fence = 'if !Owner.Current(Receipt)';
for (let index = 0; index < 4; index += 1) {
	let occurrence = -1;
	for (let cursor = 0; cursor <= index; cursor += 1)
		occurrence = form.indexOf(fence, occurrence + 1);
	assert(occurrence >= 0);
	const withdrawn = form.slice(0, occurrence) + form.slice(occurrence).replace(fence, 'if true');
	assert.throws(
		() => admission(menu.replace(form, withdrawn)),
		'every individual source fence is mandatory'
	);
	refusals += 1;
}
for (const [before, after] of [
	['Receipt, Owner, (*) => true)', '0, 0, 0)'],
	['if !((Committed is Integer) && Committed == 1)', 'if !Committed'],
	['if (Ask is Integer) && Ask == 1', 'if Ask'],
	['Options.Get("input", Ui_InputBox)', 'Options.Get("input", ForeignInputOwner)']
]) {
	assert.throws(() => admission(menu.replace(before, after)));
	refusals += 1;
}
admission(menu);

assert.equal(
	(
		remote.match(
			/LocalServerAuthEntryTokenAllowed\(ProviderId, Token, BaseUrl, LLM_LOCAL_API_SERVERS\)/g
		) || []
	).length,
	2,
	'actual generation resolver and readiness admission use the configured URL'
);
assert(
	remote.includes(
		'Owner["local_server"] := LocalServerAuthEntryTokenAllowed(ProviderId, "", BaseUrl, LLM_LOCAL_API_SERVERS)'
	)
);
assert(suite.includes('return _LLM_Menu_PromptApiEntry("", this.Port)'));
assert(suite.includes('this.World := _LSP_World()'));
assert(suite.includes('for Provider in ["openai", "openai_compat"]'));
for (const owner of [
	'_WAA_Accepted',
	'_WAA_Keyless',
	'_WAA_Cancelled',
	'_WAA_Stale',
	'_WAA_InvalidAnswer',
	'_WAA_SerializationRefused',
	'_WAA_SecondTargetLocked',
	'_WAA_ForeignApiField',
	'_WAA_InputThrows',
	'_WAA_OfferThrows'
]) {
	assert(suite.includes(owner + '('), 'real native regression owner is present: ' + owner);
}
assert(suite.includes('AssertEqual(2, Form.World.PhysicalFault.NativeRefusals)'));
assert(suite.includes('LLM_ApiToken_Decrypt(Persisted[3]["Token"])'));
assert(suite.includes('AssertEqual(Foreign, FSReadUtf8Exact(Form.World.ApiPath))'));
assert(
	suite.includes(
		'LLM_RemoteIsReady_Async(Entry, (Value) => State["results"].Push(Value), Owner, Port)'
	)
);
assert(suite.includes('AssertFalse(State["headers"].Has("Authorization")'));
for (const status of [200, 401, 403, 204])
	assert(suite.includes('_WAA_ReadyReply.Bind(Provider, ' + status + ','));
assert(suite.includes('for Result in ["Cancel", "Timeout"]'));
assert(suite.includes('for Mutation in ["menu", "active", "config", "api"]'));
console.log(
	`PASS Windows API Add source controls: original/inverse admitted; ${refusals} withdrawals refused. Native Windows cases: NOT_RUN (82 authored; 12 use injected HTTP replies).`
);
