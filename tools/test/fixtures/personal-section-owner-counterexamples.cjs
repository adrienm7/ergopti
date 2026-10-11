// tools/test/fixtures/personal-section-owner-counterexamples.cjs

/** Independent controls for the actual Mac personal_main_sections compose edge. */
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const {
	personalSectionChoicePublication
} = require('../../lib/menu-hotstring-language-binding.cjs');

// Handwritten from the actual original raw row, independently of the shared receiver.
const ORIGINAL_SECTION_ROW = `
				target[#target + 1] = {
					label    = sec.count ~= nil and (lbl .. " (" .. fmt_count(sec.count) .. ")") or lbl,
					checked  = sec_on or nil,
					action       = (group_enabled and not paused)
							   and toggleSectionFn(ctx, group_name, sec.name, lbl, admission) or nil,
					disabled = not group_enabled or paused or nil,
				}`;

module.exports = function verifyPersonalSectionOwner(base, manifest) {
	const source = fs.readFileSync(
		path.join(base, 'macos/ui/menu/menu_hotstrings_custom.lua'),
		'utf8'
	);
	const admits = (candidate = source, data = manifest, platform = 'hs') =>
		personalSectionChoicePublication(candidate, platform, data);
	assert.deepEqual(manifest.hotstring_personal_section_choice, [
		{
			type: 'check',
			id: 'personal_section_toggle',
			caption_source: 'native',
			caption_getter: 'personal_section_label',
			checked_when: ['personal_section_selected'],
			disabled_when: ['personal_section_ready'],
			platforms: ['hs'],
			unavailable: 'hide'
		}
	]);
	assert.equal(
		admits(),
		true,
		'actual section check, delegate, getters and complete personal content handoff'
	);
	let controls = 0;
	for (const candidate of ['', JSON.stringify(source), '--[=[\n' + source + '\n]=]']) {
		assert.equal(admits(candidate), false, 'absent, quoted or comment-only source refuses');
		controls++;
	}
	for (const platform of ['ahk', 'linux']) {
		assert.equal(
			admits(source, manifest, platform),
			false,
			'another platform cannot borrow the Mac section owner'
		);
		controls++;
	}
	const coordinates = [
		[
			'ManifestMenu.check_row("hotstring_personal_section_choice", "personal_section_toggle"',
			'Foreign.check_row("hotstring_personal_section_choice", "personal_section_toggle"'
		],
		[
			'"hotstring_personal_section_choice", "personal_section_toggle"',
			'"foreign_section_choice", "personal_section_toggle"'
		],
		['personal_section_toggle = action,', 'personal_section_toggle = function() return false end,'],
		[
			'local action = toggleSectionFn(ctx, group_name, sec.name, lbl, admission)',
			'local action = function() return false end'
		],
		[
			'local action = toggleSectionFn(ctx, group_name, sec.name, lbl, admission)',
			'local toggleSectionFn = Foreign\n\t\t\t\tlocal action = toggleSectionFn(ctx, group_name, sec.name, lbl, admission)'
		],
		[
			'personal_section_label = function() return caption end,',
			'personal_section_label = function() return "foreign" end,'
		],
		[
			'personal_section_selected = function() return sec_on end,',
			'personal_section_selected = function() return false end,'
		],
		[
			'personal_section_ready = function() return ready end,',
			'personal_section_ready = function() return true end,'
		],
		['local ready = group_enabled and not paused', 'local ready = true'],
		['if type(row) ~= "table" then return false end', 'if false then return false end'],
		['if not ready then row.action = nil end', 'if false then row.action = nil end'],
		[
			'if row.checked == false then row.checked = nil end',
			'if row.checked == false then row.checked = false end'
		],
		[
			'if row.checked == false then row.checked = nil end\n\t\t\t\ttarget[#target + 1] = row',
			'if row.checked == false then row.checked = nil end\n\t\t\t\ttarget[#target + 1] = {}'
		],
		[
			'if row.checked == false then row.checked = nil end\n\t\t\t\ttarget[#target + 1] = row',
			'if row.checked == false then row.checked = nil end\n\t\t\t\trow = {}\n\t\t\t\ttarget[#target + 1] = row'
		],
		[
			'if row.checked == false then row.checked = nil end\n\t\t\t\ttarget[#target + 1] = row',
			'if row.checked == false then row.checked = nil end\n\t\t\t\ttarget = {}\n\t\t\t\ttarget[#target + 1] = row'
		],
		[
			'local has_real = false\n\t\tfor _, sec in ipairs(secs) do',
			'local has_real = false\n\t\tfor _, sec in ipairs({}) do'
		],
		['elseif not sec.is_module_placeholder then', 'elseif false then'],
		[
			'local row = ManifestMenu.check_row("hotstring_personal_section_choice"',
			'return false\n\t\t\t\tlocal row = ManifestMenu.check_row("hotstring_personal_section_choice"'
		],
		[
			'local row = ManifestMenu.check_row("hotstring_personal_section_choice"',
			'local ManifestMenu = Foreign\n\t\t\t\tlocal row = ManifestMenu.check_row("hotstring_personal_section_choice"'
		],
		[
			'local ok, admitted = pcall(admission)',
			'local ok, admitted = pcall(function() return true end)'
		],
		['return mutator(group_name, sec_name)', 'return true'],
		[
			'local admission = gname ~= "personal" and PersonalFileScope.bind(ctx, record) or nil',
			'local admission = gname ~= "personal" and function() return true end or nil'
		],
		[
			'local admission = gname ~= "personal" and PersonalFileScope.bind(ctx, record) or nil',
			'local PersonalFileScope = Foreign\n\t\tlocal admission = gname ~= "personal" and PersonalFileScope.bind(ctx, record) or nil'
		],
		[
			'if append_section_rows(g_rows, gname, g_secs, g_enabled, admission) ~= true then return nil end',
			'if Foreign(g_rows, gname, g_secs, g_enabled, admission) ~= true then return nil end'
		],
		[
			'if append_section_rows(g_rows, gname, g_secs, g_enabled, admission) ~= true then return nil end',
			'append_section_rows(g_rows, gname, g_secs, g_enabled, admission)'
		],
		[
			'for _, row in ipairs(g_rows) do main_sections[#main_sections + 1] = row end',
			'for _, row in ipairs(g_rows) do main_sections[#main_sections + 1] = {} end'
		],
		[
			'["personal_main_sections"] = function() return main_sections end,',
			'["personal_main_sections"] = function() return {} end,'
		],
		[
			'local menu_items = ManifestMenu.template_rows("hotstring_personal_content_frame"',
			'main_sections = {}\n\tlocal menu_items = ManifestMenu.template_rows("hotstring_personal_content_frame"'
		],
		['if type(menu_items) ~= "table" then return nil end', 'if false then return nil end'],
		[
			'submenu = scope_menu(scope_names, {}, menu_items),',
			'submenu = scope_menu(scope_names, {}, {}),'
		],
		[
			'["hotstring_category_sections"] = function() return section_rows end,',
			'["hotstring_category_sections"] = function() return {} end,'
		],
		['\nreturn M\n', '\nManifestMenu.check_row = Foreign\nreturn M\n'],
		[
			'\nreturn M\n',
			'\nlocal captured_facade = ManifestMenu\ncaptured_facade.check_row = Foreign\nreturn M\n'
		],
		[
			'\nreturn M\n',
			'\nlocal captured_native = M\ncaptured_native.build_custom = Foreign\nreturn M\n'
		],
		['local fmt_count = Labels.fmt_count', 'local fmt_count = function() return "foreign" end']
	];
	for (const [before, after] of coordinates) {
		assert.equal(source.split(before).length - 1, 1, 'one genuine mutation coordinate: ' + before);
		assert.equal(
			admits(source.replace(before, after)),
			false,
			'actual section owner withdrawal refuses: ' + before
		);
		assert.equal(admits(), true, 'exact source repair preserves the original owner');
		controls++;
	}
	// Independent completed-port custody withdrawals; all original controls stay intact.
	const custodyCoordinates = [
		[
			'if row.checked == false then row.checked = nil end',
			'if row.checked == false then row.checked = nil end\n\t\t\t\tlocal held_target = target\n\t\t\t\theld_target[1] = {}'
		],
		[
			'if row.checked == false then row.checked = nil end',
			'if row.checked == false then row.checked = nil end\n\t\t\t\tForeign(target)'
		],
		[
			'if row.checked == false then row.checked = nil end',
			'if row.checked == false then row.checked = nil end\n\t\t\t\tlocal held_row = row\n\t\t\t\theld_row.label = "foreign"'
		],
		[
			'if row.checked == false then row.checked = nil end',
			'if row.checked == false then row.checked = nil end\n\t\t\t\tForeign.box = target'
		],
		[
			'if append_section_rows(g_rows, gname, g_secs, g_enabled, admission) ~= true then return nil end',
			'if append_section_rows(g_rows, gname, g_secs, g_enabled, admission) ~= true then return nil end\n\t\tlocal held_grows = g_rows\n\t\theld_grows[1] = {}'
		],
		[
			'if append_section_rows(g_rows, gname, g_secs, g_enabled, admission) ~= true then return nil end',
			'if append_section_rows(g_rows, gname, g_secs, g_enabled, admission) ~= true then return nil end\n\t\tForeign(g_rows)'
		],
		[
			'if append_section_rows(g_rows, gname, g_secs, g_enabled, admission) ~= true then return nil end',
			'if append_section_rows(g_rows, gname, g_secs, g_enabled, admission) ~= true then return nil end\n\t\tg_rows[1].checked = false'
		],
		[
			'local menu_items = ManifestMenu.template_rows("hotstring_personal_content_frame"',
			'local held_main = main_sections\n\theld_main[1] = {}\n\tlocal menu_items = ManifestMenu.template_rows("hotstring_personal_content_frame"'
		],
		[
			'local menu_items = ManifestMenu.template_rows("hotstring_personal_content_frame"',
			'Foreign(main_sections)\n\tlocal menu_items = ManifestMenu.template_rows("hotstring_personal_content_frame"'
		],
		[
			'local menu_items = ManifestMenu.template_rows("hotstring_personal_content_frame"',
			'for _, held_main_row in ipairs(main_sections) do held_main_row.checked = false end\n\tlocal menu_items = ManifestMenu.template_rows("hotstring_personal_content_frame"'
		],
		[
			'if type(menu_items) ~= "table" then return nil end',
			'if type(menu_items) ~= "table" then return nil end\n\tlocal held_items = menu_items\n\theld_items[1] = {}'
		],
		[
			'if type(menu_items) ~= "table" then return nil end',
			'if type(menu_items) ~= "table" then return nil end\n\tForeign(menu_items)'
		],
		[
			'if type(menu_items) ~= "table" then return nil end',
			'if type(menu_items) ~= "table" then return nil end\n\tlocal held_items\n\theld_items = menu_items\n\theld_items[1] = {}'
		],
		[
			'if type(menu_items) ~= "table" then return nil end',
			'if type(menu_items) ~= "table" then return nil end\n\tlocal held_box = { menu_items }\n\theld_box[1][1] = {}'
		],
		[
			'if type(menu_items) ~= "table" then return nil end',
			'if type(menu_items) ~= "table" then return nil end\n\tForeign(function() return menu_items end)'
		],
		[
			'if type(menu_items) ~= "table" then return nil end',
			'if type(menu_items) ~= "table" then return nil end\n\tfunction Foreign.borrow() return menu_items end'
		],
		[
			'if type(menu_items) ~= "table" then return nil end',
			'if type(menu_items) ~= "table" then return nil end\n\tfor _, held_item in ipairs(menu_items) do held_item.checked = false end'
		],
		[
			'if type(menu_items) ~= "table" then return nil end',
			'if type(menu_items) ~= "table" then return nil end\n\tlocal held_first = menu_items\n\tlocal held_second = held_first\n\theld_second[1] = {}'
		],
		[
			'if type(menu_items) ~= "table" then return nil end',
			'if type(menu_items) ~= "table" then return nil end\n\tmain_sections[#main_sections + 1] = {}'
		],
		[
			'local function scope_menu(names, file_rows, section_rows)',
			'local function scope_menu(names, file_rows, section_rows)\n\t\tlocal held_scope = section_rows\n\t\theld_scope[1] = {}'
		],
		[
			'local function scope_menu(names, file_rows, section_rows)',
			'local function scope_menu(names, file_rows, section_rows)\n\t\tForeign(section_rows)'
		],
		[
			'local function file_menu_for_group(gname, rows, check, readonly)',
			'local function file_menu_for_group(gname, rows, check, readonly)\n\t\tlocal held_file_rows = rows\n\t\theld_file_rows[1] = {}'
		],
		[
			'local function file_menu_for_group(gname, rows, check, readonly)',
			'local function file_menu_for_group(gname, rows, check, readonly)\n\t\tForeign(rows)'
		]
	];
	for (const [before, after] of custodyCoordinates) {
		assert.equal(
			source.split(before).length - 1,
			1,
			'one actual completed-port custody coordinate: ' + before
		);
		assert.equal(
			admits(source.replace(before, after)),
			false,
			'actual alias or foreign escape refuses: ' + before
		);
		assert.equal(admits(), true, 'exact repair restores original completed-port custody');
		controls++;
	}
	const start = '\n\t\t\t\tlocal ready = group_enabled and not paused',
		end = '\n\t\t\t\ttarget[#target + 1] = row';
	assert.equal(source.split(start).length - 1, 1, 'one real section row start');
	const at = source.indexOf(start),
		last = source.indexOf(end, at);
	assert(last > at, 'the actual scoped row sink follows its typed receiver');
	const original = source.slice(0, at) + ORIGINAL_SECTION_ROW + source.slice(last + end.length);
	assert.equal(
		createHash('sha256').update(original).digest('hex'),
		'9e472930e5f677995bd745230b1016eb613cf02e834e2030f0bf3e530fbf6102',
		'independent captured current V2 original producer, not a regenerated oracle'
	);
	assert.equal(
		admits(original),
		false,
		'the genuine original raw provider cannot authenticate the new typed compose edge'
	);
	controls++;
	for (const mutate of [
		(data) => delete data.hotstring_personal_section_choice,
		(data) =>
			data.hotstring_personal_section_choice.push(
				structuredClone(data.hotstring_personal_section_choice[0])
			),
		(data) => {
			data.hotstring_personal_section_choice[0].type = 'group';
		},
		(data) => {
			data.hotstring_personal_section_choice[0].caption_getter = 'foreign_caption';
		},
		(data) => {
			data.hotstring_personal_section_choice[0].checked_when = ['foreign_selected'];
		},
		(data) => {
			data.hotstring_personal_section_choice[0].disabled_when = [];
		},
		(data) => {
			data.hotstring_personal_section_choice[0].platforms = ['linux'];
		},
		(data) => {
			data.hotstring_personal_section_choice[0].unavailable = 'disable';
		},
		(data) => {
			data.hotstring_personal_content_frame.find(
				(row) => row.id === 'personal_main_sections'
			).type = 'group';
		},
		(data) => {
			data.hotstring_personal_content_frame = data.hotstring_personal_content_frame.filter(
				(row) => row.id !== 'personal_main_sections'
			);
		}
	]) {
		const changed = structuredClone(manifest);
		mutate(changed);
		assert.equal(admits(source, changed), false, 'missing or changed genuine declaration refuses');
		assert.equal(admits(), true, 'exact declaration repair restores actual ownership');
		controls++;
	}
	return controls;
};
