// tools/test/fixtures/hotstring-language-owner-counterexamples.cjs

/** Independent withdrawal controls for the actual Hotstrings language producer routes. */
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const {
	hotstringLanguagePublication,
	files
} = require('../../lib/menu-hotstring-language-binding.cjs');

module.exports = function verifyHotstringLanguageOwners(base, manifest) {
	let controls = 0;
	for (const platform of ['ahk', 'hs', 'linux']) {
		const sources = Object.fromEntries(
			files[platform].map((file) => [file, fs.readFileSync(path.join(base, file), 'utf8')])
		);
		const target =
			platform === 'ahk' ? 'hotstring_language_parent_windows' : 'hotstring_language_parent_lua';
		const admits = (candidate = sources, declaration = manifest, key = target) =>
			hotstringLanguagePublication(candidate, declaration, platform, key);
		assert.equal(admits(), true, platform + ': actual complete declared language owner');
		for (const key of ['hotstring_scope_checkbox', 'hotstring_language_frame', target]) {
			assert.equal(
				admits(sources, manifest, key),
				true,
				'each graph edge owes the same actual owner'
			);
			for (const change of [
				(rows) => [],
				(rows) => [...rows, structuredClone(rows[0])],
				(rows) => rows.map((row) => ({ ...row, type: 'label' })),
				(rows) => rows.map((row) => ({ ...row, caption_getter: 'unread_getter' })),
				(rows) => rows.map((row) => ({ ...row, i18n: 'unowned.label' })),
				(rows) => [...rows].reverse()
			]) {
				const changed = structuredClone(manifest);
				changed[key] = change(changed[key]);
				// Reversing a singleton is not a mutation and is not counted as a control.
				if (JSON.stringify(changed[key]) === JSON.stringify(manifest[key])) continue;
				assert.equal(
					admits(sources, changed),
					false,
					key + ': malformed/empty/reordered declaration'
				);
				controls++;
			}
			const missing = structuredClone(manifest);
			delete missing[key];
			assert.equal(admits(sources, missing), false, 'missing required canonical source');
			controls++;
		}
		const orphaned = structuredClone(manifest);
		orphaned.hotstrings_menu = orphaned.hotstrings_menu.filter(
			(row) => row.id !== 'hotstring_languages'
		);
		assert.equal(
			admits(sources, orphaned),
			false,
			'no live parent provider means no ownership credit'
		);
		controls++;
		for (const file of files[platform]) {
			const actual = sources[file];
			const quoted =
				platform === 'ahk'
					? '"' + actual.replaceAll('`', '``').replaceAll('"', '`"').replaceAll('\n', '`n') + '"'
					: JSON.stringify(actual);
			const commented = actual
				.split('\n')
				.map((line) => (platform === 'ahk' ? '; ' : '-- ') + line)
				.join('\n');
			for (const dormant of [
				'',
				quoted,
				commented,
				platform === 'ahk' ? 'if false {\n' + actual + '\n}' : 'if false then\n' + actual + '\nend'
			]) {
				assert.equal(
					admits({ ...sources, [file]: dormant }),
					false,
					'withdrawn/quoted/comment-only/dead native source earns no credit'
				);
				controls++;
			}
		}
		const languageFile = files[platform][0],
			language = sources[languageFile];
		const signature =
			platform === 'ahk'
				? '_HS_LanguageRows() {'
				: platform === 'hs'
					? 'local function build_hotstrings_rows(ctx, menu_mods)'
					: 'local function _manifest_hotstring_rows(ctx, config)';
		assert.equal(language.split(signature).length - 1, 1, 'unique actual physical owner preimage');
		const emptyOwner =
			platform === 'ahk' ? signature + '\nreturn []\n}' : signature + '\nreturn nil\nend';
		assert.equal(
			admits({
				...sources,
				[languageFile]:
					language.replace(
						signature,
						signature.replace(
							platform === 'ahk'
								? '_HS_LanguageRows'
								: platform === 'hs'
									? 'build_hotstrings_rows'
									: '_manifest_hotstring_rows',
							'unused_language_owner'
						)
					) +
					'\n' +
					emptyOwner
			}),
			false,
			'unused native neighbor cannot lend its rows to an empty real producer'
		);
		controls++;
		for (const [before, after, reason] of [
			[
				platform === 'ahk' ? 'MenuRenderer_TemplateRows' : 'ManifestMenu.template_rows',
				platform === 'ahk' ? 'Foreign_TemplateRows' : 'Foreign.template_rows',
				'foreign renderer'
			],
			['hotstring_language_count', 'withdrawn_language_count', 'unread count getter'],
			[
				'hotstring_language_categories',
				'withdrawn_language_categories',
				'disconnected category provider'
			],
			[
				platform === 'ahk'
					? 'Map("hotstring_language_children", Items)'
					: '{ hotstring_language_children = items }',
				platform === 'ahk'
					? 'Map("hotstring_language_children", [])'
					: '{ hotstring_language_children = {} }',
				'empty completed child'
			],
			[
				platform === 'ahk'
					? '_HS_LanguageSwitchRow(Pack)'
					: platform === 'hs'
						? 'menu_mods.hotstrings.build_language_bulk_actions(ctx, names)'
						: 'all_sections_row(ids), {}',
				platform === 'ahk'
					? 'ForeignSwitch(Pack)'
					: platform === 'hs'
						? 'Foreign.bulk(ctx, names)'
						: 'Foreign.switch(ids), {}',
				'withdrawn actual scope producer'
			]
		]) {
			assert(language.includes(before), reason + ': genuine source preimage');
			const changed = language.replaceAll(before, after);
			assert.equal(admits({ ...sources, [languageFile]: changed }), false, reason);
			const decoy =
				platform === 'ahk'
					? '\nUnused() {\nDecoy := ' + before + '\n}\n'
					: '\nlocal function unused()\nlocal decoy = ' + before + '\nend\n';
			assert.equal(
				admits({ ...sources, [languageFile]: changed + decoy }),
				false,
				'decorative unused occurrence cannot restore the withdrawn actual effect'
			);
			controls += 2;
		}
		const scopeFile = files[platform][1] || languageFile,
			scope = sources[scopeFile];
		for (const [before, after] of [
			['hotstring_scope_all_on', 'withdrawn_scope_getter'],
			[
				platform === 'ahk'
					? 'Apply(!AllOn)'
					: platform === 'hs'
						? 'set_fn(not all_on)'
						: 'pcall(config.set_categories_sections, ids, not all_on)',
				'Foreign.callback()'
			]
		]) {
			assert(scope.includes(before), 'actual native checked/callback preimage');
			assert.equal(
				admits({ ...sources, [scopeFile]: scope.replaceAll(before, after) }),
				false,
				'withdrawn real checked getter or scoped writer must refuse'
			);
			controls++;
		}
		if (platform !== 'ahk') {
			assert.equal(
				admits({
					...sources,
					[scopeFile]: scope.replaceAll('"infra.manifest_menu"', '"foreign.renderer"')
				}),
				false,
				'canonical native renderer import is necessary'
			);
			controls++;
		}
		assert.equal(admits(), true, 'exact source survives every independent negative control');
	}
	controls += verifyIndependentHotstringMutants(base, manifest);
	controls += verifyPublicationGraphCounterexamples(base, manifest);
	controls += verifyLiveModuleExportCounterexamples(base, manifest);
	controls += verifySingleModuleExportCounterexamples(base, manifest);
	return controls;
};

const reviewerCases = [
	{
		platform: 'ahk',
		control: 'real producer exits before all required native effects',
		signature: '_HS_LanguageRows() {',
		injection: '\n\treturn []',
		actual: true,
		expected: false,
		mutation_source_sha256: '182d74986fd4b8cd874038f544adc200c4f742b7c3aef8f54048b43be6aeea0b'
	},
	{
		platform: 'hs',
		control: 'real producer exits before all required native effects',
		signature: 'local function build_hotstrings_rows(ctx, menu_mods)',
		injection: '\n\tdo return {} end',
		actual: true,
		expected: false,
		mutation_source_sha256: 'a50aca89ebed501ab136ecd96c0be89e1c1658ab62ef08317afa26fb1d9afbb0'
	},
	{
		platform: 'linux',
		control: 'real producer exits before all required native effects',
		signature: 'local function _manifest_hotstring_rows(ctx, config)',
		injection: '\n\tdo return {} end',
		actual: true,
		expected: false,
		mutation_source_sha256: 'c96e586786f2018ebeced6a99ad9d70e1c300a66b53a7a15075c716dece9c9fb'
	},
	{
		platform: 'ahk',
		control: 'completed canonical frame reassigned empty before parent capture',
		actual: true,
		expected: false,
		mutation_source_sha256: '5a26685f1794bdef9ed47e373f797eba4c6e90c363bab767246edc99daa83a40'
	},
	{
		platform: 'hs',
		control: 'canonical global import shadowed by foreign local in actual consumer',
		signature: 'function M.build_language_bulk_actions(ctx, group_names)',
		injection: '\n\tlocal Custom = { all_sections_row = function() return nil end }',
		actual: true,
		expected: false,
		mutation_source_sha256: '7b66658a234ac87ffc86b0810cedd13255a211bd039b9bd84a12fbd96fb43676'
	}
];

/** Applies the independently authored mutation to its actual native owner, without rebuilding an oracle. */
function mutate(source, control) {
	if (control.signature) {
		assert.equal(source.split(control.signature).length - 1, 1, 'one actual reviewer preimage');
		return source.replace(control.signature, control.signature + control.injection);
	}
	const before = 'Parents := MenuRenderer_TemplateRows("hotstring_language_parent_windows"';
	assert.equal(source.split(before).length - 1, 1, 'one actual captured-parent reviewer preimage');
	return source.replace(before, 'Items := []\n\t\t' + before);
}

/** Replays the five sealed negatives against the actual current consumer source. */
function verifyIndependentHotstringMutants(base, manifest) {
	for (const control of reviewerCases) {
		const platform = control.platform;
		const sources = Object.fromEntries(
			files[platform].map((file) => [file, fs.readFileSync(path.join(base, file), 'utf8')])
		);
		const sourceFile = control.control.includes('import shadowed')
			? files[platform][2]
			: files[platform][0];
		const target =
			platform === 'ahk' ? 'hotstring_language_parent_windows' : 'hotstring_language_parent_lua';
		assert.equal(
			hotstringLanguagePublication(sources, manifest, platform, target),
			true,
			'the actual source is admitted before its independent reviewer mutation'
		);
		const changed = { ...sources, [sourceFile]: mutate(sources[sourceFile], control) };
		assert.equal(
			hotstringLanguagePublication(changed, manifest, platform, target),
			control.expected,
			control.control + ': exact independently authored negative'
		);
		assert.equal(
			hotstringLanguagePublication(sources, manifest, platform, target),
			true,
			'the actual canonical route remains admitted after the negative'
		);
	}
	return reviewerCases.length;
}

/** The second sealed independent review: unchanged five valid-Lua counterfactuals. */
const publicationCases = [
	{
		name: 'real-language-producer-shadowed-after-declaration',
		source_file: 'linux/ui/menu/menu_builder.lua',
		mutation_file: 'real-language-producer-shadowed-after-declaration.lua',
		source_sha256: '11cbf1585cd99374375e847005d7828691bbe8df5b0219607fdfcf7cdf20b140',
		actual: true,
		expected: false,
		lua_parse_exit: 0,
		before: '\n\t--- Every known category id',
		after: '\n\tlanguage_rows = function() return {} end\n\t--- Every known category id'
	},
	{
		name: 'canonical-renderer-import-shadowed-in-real-owner',
		source_file: 'linux/ui/menu/menu_builder.lua',
		mutation_file: 'canonical-renderer-import-shadowed-in-real-owner.lua',
		source_sha256: 'c69bf314d518b1d1fee1aad2512fb1fa812efe21843eb4a7d6cd0554e66bc9f9',
		actual: true,
		expected: false,
		lua_parse_exit: 0,
		before: 'local function _manifest_hotstring_rows(ctx, config)',
		after:
			'local function _manifest_hotstring_rows(ctx, config)\n\tlocal ManifestMenu = { check_row = function() return nil end, template_rows = function() return {} end, build = function() return {} end }'
	},
	{
		name: 'returned-native-hotstrings-child-discarded',
		source_file: 'linux/ui/menu/menu_builder.lua',
		mutation_file: 'returned-native-hotstrings-child-discarded.lua',
		source_sha256: 'df144fcafde75e7bc8fb270e03599132fa1b0be3200b8f32b5600a8dfc8b19f6',
		actual: true,
		expected: false,
		lua_parse_exit: 0,
		before: 'return { label = title, checked = _hotstrings_on(ctx), submenu = items }',
		after: 'return { label = title, checked = _hotstrings_on(ctx), submenu = {} }'
	},
	{
		name: 'unconditional-true-loop-return-before-real-effects',
		source_file: 'linux/ui/menu/menu_builder.lua',
		mutation_file: 'unconditional-true-loop-return-before-real-effects.lua',
		source_sha256: '1441aaaf8f27b68ec6a0f914e3f100b930f4ffc16b8c6f9a622499d0d0b3fd9e',
		actual: true,
		expected: false,
		lua_parse_exit: 0,
		before: 'local function _manifest_hotstring_rows(ctx, config)',
		after: 'local function _manifest_hotstring_rows(ctx, config)\n\twhile true do return {} end'
	},
	{
		name: 'actual-top-level-registration-discards-genuine-child',
		source_file: 'linux/ui/menu/menu_builder.lua',
		mutation_file: 'actual-top-level-registration-discards-genuine-child.lua',
		source_sha256: '50a1417b5670b7b35ac08fbe11c6fdf6a419d9631bb9e50d491bb6c95fc3a04f',
		actual: true,
		expected: false,
		lua_parse_exit: 0,
		before: '["hotstrings"]      = _build_hotstrings,',
		after: '["hotstrings"]      = function(ctx) _build_hotstrings(ctx); return {} end,'
	}
];
function verifyPublicationGraphCounterexamples(base, manifest) {
	const platform = 'linux',
		file = files[platform][0],
		source = fs.readFileSync(path.join(base, file), 'utf8');
	const sources = { [file]: source };
	assert.equal(
		hotstringLanguagePublication(sources, manifest, platform, 'hotstring_language_parent_lua'),
		true,
		'actual complete producer-to-publication graph'
	);
	for (const control of publicationCases) {
		assert.equal(
			source.split(control.before).length - 1,
			1,
			'one exact second-review mutation preimage'
		);
		const changed = { [file]: source.replace(control.before, control.after) };
		assert.equal(
			hotstringLanguagePublication(changed, manifest, platform, 'hotstring_language_parent_lua'),
			control.expected,
			control.name + ': actual independently authored native publication withdrawal'
		);
		assert.equal(
			hotstringLanguagePublication(sources, manifest, platform, 'hotstring_language_parent_lua'),
			true,
			'genuine physical graph remains admitted after withdrawal'
		);
	}
	return publicationCases.length;
}

/** Exact third-review export liveness negatives; the physical public methods must be exported. */
const exportCases = [
	{
		platform: 'linux',
		name: 'actual-module-export-discarded-linux',
		source_file: 'linux/ui/menu/menu_builder.lua',
		mutation_file: 'actual-module-export-discarded-linux.lua',
		source_sha256: '8b07dc4634d5a1b3b0dba4c40eeca8735fc8ab08da77c4db999aff107e254a05',
		actual: true,
		expected: false
	},
	{
		platform: 'hs',
		name: 'actual-module-export-discarded-hs',
		source_file: 'macos/ui/menu/builder.lua',
		mutation_file: 'actual-module-export-discarded-hs.lua',
		source_sha256: 'dfc096e21cd9fc473ffd18d994da0631ba2dfa684e9c87b15c563ee68702912c',
		actual: true,
		expected: false
	}
];
function verifyLiveModuleExportCounterexamples(base, manifest) {
	for (const control of exportCases) {
		const sources = Object.fromEntries(
			files[control.platform].map((file) => [file, fs.readFileSync(path.join(base, file), 'utf8')])
		);
		const source = sources[control.source_file],
			before = '\nreturn M';
		assert.equal(
			source.split(before).length - 1,
			1,
			'one actual final module export reviewer preimage'
		);
		assert.equal(
			hotstringLanguagePublication(
				sources,
				manifest,
				control.platform,
				'hotstring_language_parent_lua'
			),
			true,
			'actual live method-carrying module export'
		);
		const changed = {
			...sources,
			[control.source_file]: source.replace(before, '\ndo return {} end' + before)
		};
		assert.equal(
			hotstringLanguagePublication(
				changed,
				manifest,
				control.platform,
				'hotstring_language_parent_lua'
			),
			control.expected,
			control.name + ': exact independently authored export withdrawal'
		);
		assert.equal(
			hotstringLanguagePublication(
				sources,
				manifest,
				control.platform,
				'hotstring_language_parent_lua'
			),
			true,
			'restored genuine module export remains admitted'
		);
	}
	return exportCases.length;
}

/** Exact fourth-review first-export negatives: require must receive the one method-carrying module table. */
const singleExportCases = [
	{
		platform: 'linux',
		name: 'actual-first-module-export-empty-linux',
		source_file: 'linux/ui/menu/menu_builder.lua',
		mutation_file: 'actual-first-module-export-empty-linux.lua',
		source_sha256: 'e4477baef866322a7280cd6547cbafea5e3fb09a9eac4e09c655cd05fbe9aa29',
		original_source_sha256: '936043f79f4a2061b6b0f3e12f672156f52fbed0edb6f5347ffd28d23d6302f1',
		actual: true,
		expected: false
	},
	{
		platform: 'hs',
		name: 'actual-first-module-export-empty-hs',
		source_file: 'macos/ui/menu/builder.lua',
		mutation_file: 'actual-first-module-export-empty-hs.lua',
		source_sha256: '17a33cb0ee798de321aa1e68d8d27888694e9723d42ea8ac89d363c9779bfe60',
		original_source_sha256: '5f1973978f4aeae172eefa16f9f1c22a546648edf63f1ad3ffd429aabc3c4b32',
		actual: true,
		expected: false
	}
];
function verifySingleModuleExportCounterexamples(base, manifest) {
	for (const control of singleExportCases) {
		const sources = Object.fromEntries(
			files[control.platform].map((file) => [file, fs.readFileSync(path.join(base, file), 'utf8')])
		);
		const source = sources[control.source_file],
			before = '\nreturn M';
		assert.equal(
			source.split(before).length - 1,
			1,
			'one actual final single module export reviewer preimage'
		);
		assert.equal(
			hotstringLanguagePublication(
				sources,
				manifest,
				control.platform,
				'hotstring_language_parent_lua'
			),
			true,
			'actual single live method-carrying module export'
		);
		const changed = { ...sources, [control.source_file]: source.replace(before, '\nreturn {}, M') };
		assert.equal(
			hotstringLanguagePublication(
				changed,
				manifest,
				control.platform,
				'hotstring_language_parent_lua'
			),
			control.expected,
			control.name + ': exact independently authored first-export withdrawal'
		);
		assert.equal(
			hotstringLanguagePublication(
				sources,
				manifest,
				control.platform,
				'hotstring_language_parent_lua'
			),
			true,
			'restored genuine single module export remains admitted'
		);
	}
	return singleExportCases.length;
}
