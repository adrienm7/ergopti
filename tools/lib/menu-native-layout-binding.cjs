// tools/lib/menu-native-layout-binding.cjs

'use strict';
const { scriptTokens } = require('./script-source.cjs');

/** Finite necessary Layout-owner evidence; it does not certify native TIS execution. */
function nativeLayoutTemplatePublication(source, section, definition, ownership) {
	if (typeof source !== 'string' || !Array.isArray(definition) || definition.length === 0)
		return false;
	const lex = (text) => {
		const tokens = scriptTokens(text, '.lua'),
			stack = [],
			scopes = [],
			closes = new Map();
		let awaitingDo = 0;
		for (let i = 0; i < tokens.length; i++) {
			scopes[i] = stack.length;
			const token = tokens[i];
			if (token.kind !== 'identifier' || ['.', ':'].includes(tokens[i - 1]?.value)) continue;
			if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
				stack.push({ word: token.value, at: i });
				if (['for', 'while'].includes(token.value)) awaitingDo++;
			} else if (token.value === 'do') {
				if (awaitingDo) awaitingDo--;
				else stack.push({ word: 'do', at: i });
			} else if (token.value === 'end' || token.value === 'until') {
				const block = stack.pop();
				if (!block || (token.value === 'until') !== (block.word === 'repeat')) return null;
				closes.set(block.at, i);
			}
		}
		return stack.length ? null : { text, tokens, scopes, closes };
	};
	const positions = (unit, text) => {
		if (!unit) return [];
		const wanted = scriptTokens(text, '.lua'),
			found = [];
		for (let at = 0; at < unit.tokens.length; at++) {
			if (['.', ':'].includes(unit.tokens[at - 1]?.value)) continue;
			if (
				wanted.every((token, offset) => {
					const actual = unit.tokens[at + offset];
					return (
						actual?.kind === token.kind &&
						actual.value === token.value &&
						(token.kind !== 'string' ||
							unit.text.slice(actual.start, actual.end) === text.slice(token.start, token.end))
					);
				})
			)
				found.push(at);
		}
		return found;
	};
	const bodyOf = (unit, signature) => {
		const found = positions(unit, signature);
		if (found.length !== 1 || unit.scopes[found[0]] !== 0) return null;
		const start = found[0],
			count = scriptTokens(signature, '.lua').length;
		const functionAt = unit.tokens.findIndex(
			(token, at) => at >= start && at < start + count && token.value === 'function'
		);
		const end = unit.closes.get(functionAt);
		if (end === undefined) return null;
		return lex(unit.text.slice(unit.tokens[start + count - 1].end, unit.tokens[end].start));
	};
	const body = (signature) => bodyOf(lex(source), signature);
	const one = (unit, statement) => positions(unit, statement).length === 1;
	const ordered = (unit, statements) => {
		let previous = -1;
		for (const statement of statements) {
			const found = positions(unit, statement);
			if (found.length !== 1 || found[0] <= previous) return false;
			previous = found[0];
		}
		return true;
	};
	const scalar = {
		layout_bundle_in_list: 'layout_bundle_version',
		layout_bundle_update_install_first: 'layout_bundle_version',
		layout_bundle_upgrade_to: 'layout_bundle_version',
		layout_bundle_variant_parent: 'layout_bundle_version',
		layout_native_record_choice: 'layout_native_caption'
	};
	const vectors = {
		layout_bundle_installed: ['layout_install_scope', 'layout_install_latest'],
		layout_bundle_update: ['layout_install_scope', 'layout_install_old', 'layout_install_latest'],
		layout_bundle_install: [
			'layout_install_emoji',
			'layout_install_scope',
			'layout_install_latest'
		],
		layout_bundle_upgrade: ['layout_bundle_old_version', 'layout_bundle_version'],
		layout_bundle_variant_added: ['layout_variant_label', 'layout_bundle_version'],
		layout_bundle_variant_add: ['layout_variant_label', 'layout_bundle_version']
	};
	if (
		scalar[section] &&
		(definition.length !== 1 || definition[0].caption_getter !== scalar[section])
	)
		return false;
	if (
		vectors[section] &&
		!require('node:util').isDeepStrictEqual(definition[0]?.caption_getters, vectors[section])
	)
		return false;
	if (
		section === 'layout_bundle_frame' &&
		!require('node:util').isDeepStrictEqual(
			definition.map((row) => [row.type, row.id]),
			[
				['list', 'layout_bundle_system'],
				['list', 'layout_bundle_user'],
				['list', 'layout_bundle_status']
			]
		)
	)
		return false;
	const helper = body('local function layout_declared_row(section, commands, getters, children)');
	const expected = lex(`local renderer = require("infra.manifest_menu")
		local rows = type(renderer.template_rows) == "function"
			and renderer.template_rows(section, commands or {}, getters or {}, children or {}) or nil
		if type(rows) ~= "table" or #rows ~= 1 then return nil end
		return rows[1]`);
	if (
		!helper ||
		!expected ||
		helper.tokens.length !== expected.tokens.length ||
		!helper.tokens.every(
			(token, at) =>
				token.kind === expected.tokens[at].kind && token.value === expected.tokens[at].value
		)
	)
		return false;
	const whole = lex(source);
	if (
		positions(whole, 'local require').length ||
		positions(whole, 'require =').length ||
		positions(whole, 'local pcall').length ||
		positions(whole, 'pcall =').length ||
		['layout_declared_row', 'layout_native_choice'].some(
			(name) =>
				positions(whole, 'local function ' + name).length !== 1 ||
				positions(whole, name + ' =').length
		)
	)
		return false;
	const build = body('function M.build(ctx)');
	if (
		!build ||
		positions(build, 'local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")').filter(
			(at) => build.scopes[at] === 0
		).length !== 1 ||
		positions(build, 'ManifestMenu =').filter((at) => build.scopes[at] === 0).length !== 1 ||
		!one(
			build,
			`if not ok_mm or type(ManifestMenu.build) ~= "function" then
			Logger.error(LOG, "Manifest renderer unavailable — the layout list is not rendered.")
			return nil
		end`
		)
	)
		return false;
	if (
		['layout_declared_row', 'layout_native_choice'].some(
			(name) => positions(build, 'local ' + name).length || positions(build, name + ' =').length
		)
	)
		return false;
	if (
		!ordered(build, [
			'local declared_bundle_rows = bundle_frame_rows()',
			'local custom_rows = custom_layout_rows(update_menu, ManifestMenu)',
			'local active_rows = active_layout_rows()',
			'local submenu = ManifestMenu.build("layout_menu", "Layout", nil, nil, render_ctx, {',
			'return ManifestMenu.group_row("layout_native_parent", "layout_parent_content", submenu, {})'
		])
	)
		return false;
	if (
		!one(build, '["layout_bundle"] = function() return declared_bundle_rows end') ||
		!one(build, '["custom_layouts"] = function() return custom_rows end') ||
		!one(build, '["active_layouts"] = function() return active_rows end') ||
		!one(build, '["layout_switching"] = function() return switching_rows end')
	)
		return false;
	// A census credit additionally proves the actual callable/data owner. The
	// original publication predicate remains unchanged for its existing callers.
	if (ownership !== undefined) {
		if (!['behavior', 'inert'].includes(ownership)) return false;
		const exact = (unit, text) => {
			const expected = lex(text);
			return (
				unit &&
				expected &&
				unit.tokens.length === expected.tokens.length &&
				unit.tokens.every(
					(token, at) =>
						token.kind === expected.tokens[at].kind &&
						token.value === expected.tokens[at].value &&
						(token.kind !== 'string' ||
							unit.text.slice(token.start, token.end) ===
								text.slice(expected.tokens[at].start, expected.tokens[at].end))
				)
			);
		};
		const localPort = (name, declaration) =>
			one(whole, declaration) &&
			positions(whole, 'local ' + name).length === 1 &&
			positions(whole, name + ' =').length === 1;
		if (
			!localPort('install', 'local install = require("modules.keymap.layout_install")') ||
			!localPort('version_str', 'local version_str = install.version_str') ||
			positions(whole, 'local layout_declared_row').length ||
			positions(whole, 'local layout_native_choice').length
		)
			return false;
		const frame = bodyOf(build, 'local function bundle_frame_rows()');
		if (
			positions(build, 'local bundle_frame_rows').length ||
			positions(build, 'bundle_frame_rows =').length ||
			!ordered(frame, [
				'local function system_provider() return latest and {bundle_rows[1]} or {} end',
				'local function user_provider() return latest and {bundle_rows[2]} or {} end',
				'local function status_provider() return {bundle_rows[#bundle_rows]} end',
				'local rows = ManifestMenu.template_rows("layout_bundle_frame", {}, {}, {',
				'layout_bundle_system = system_provider',
				'layout_bundle_user = user_provider',
				'layout_bundle_status = status_provider',
				'if type(rows) ~= "table" or #rows ~= #bundle_rows then return nil end',
				'if latest then return rows end',
				'for _, row in ipairs(rows) do missing[#missing + 1] = row end',
				'return missing'
			])
		)
			return false;
		const installHandoffs = () =>
			[
				['system', '🔐', 'system_best'],
				['user', '📥', 'user_best']
			].every(([scope, emoji, best]) =>
				one(
					build,
					`bundle_rows[#bundle_rows + 1] = build_install_item(
				i18n.get("menu.layout.scope_${scope}"), "${emoji}", ${best}, latest, latest_ver,
				function() run_install_and_chain(function() return install_${scope}(bundles_dir, latest) end, legacy_active, update_menu) end
			)`
				)
			);
		if (section === 'layout_bundle_variant_added' || section === 'layout_bundle_variant_add') {
			if (
				positions(build, 'local variant_provider').length ||
				positions(build, 'variant_provider =').length ||
				!ordered(build, [
					'if #add_sub ~= #variants then return nil end',
					'local function variant_provider() return add_sub end',
					`bundle_rows[#bundle_rows + 1] = layout_declared_row("layout_bundle_variant_parent", {}, {
						layout_bundle_version = function() return latest_str end,
					}, { layout_variant_choices = variant_provider })`
				])
			)
				return false;
		}
		if (ownership === 'inert') {
			if (
				section === 'layout_bundle_install_first' &&
				Object.keys(definition[0]).some(
					(field) => !['type', 'id', 'i18n', 'platforms', 'unavailable'].includes(field)
				)
			)
				return false;
			const installed = body(
				'local function build_install_item(scope_label, emoji_install, installed, latest_name, latest_ver, do_install)'
			);
			if (section === 'layout_bundle_installed') {
				if (
					!installHandoffs() ||
					!exact(
						installed,
						`local getters = {
					layout_install_scope = function() return scope_label end,
					layout_install_emoji = function() return emoji_install end,
					layout_install_latest = function() return version_str(latest_ver) end,
					layout_install_old = function() return installed and version_str(installed.version) or "" end,
				}
				if installed and not version_gt(latest_ver, installed.version) then
					return layout_declared_row("layout_bundle_installed", {}, getters)
				end
				if installed then return layout_declared_row("layout_bundle_update", { layout_install = do_install }, getters) end
				return layout_declared_row("layout_bundle_install", { layout_install = do_install }, getters)`
					)
				)
					return false;
			} else {
				const data = {
					layout_bundle_in_list: `bundle_rows[#bundle_rows + 1] = layout_declared_row("layout_bundle_in_list", {}, {
						layout_bundle_version = function() return version_str(installed_ver) end,
					})`,
					layout_bundle_update_install_first: `bundle_rows[#bundle_rows + 1] = layout_declared_row("layout_bundle_update_install_first", {}, {
						layout_bundle_version = function() return latest_str end,
					})`,
					layout_bundle_variant_added: `add_sub[#add_sub + 1] = layout_declared_row("layout_bundle_variant_added", {}, {
						layout_variant_label = function() return label end,
						layout_bundle_version = function() return latest_str end,
					})`,
					layout_bundle_install_first:
						'bundle_rows[#bundle_rows + 1] = layout_declared_row("layout_bundle_install_first", {}, {})'
				};
				if (!Object.hasOwn(data, section) || !one(build, data[section])) return false;
			}
		} else {
			const deferred = body('local function defer_tis_call(fn)');
			if (
				!localPort(
					'input_sources',
					'local input_sources = require("modules.keymap.input_sources")'
				) ||
				!localPort(
					'upgrade_active_list_async',
					'local upgrade_active_list_async = input_sources.upgrade_active_list_async'
				) ||
				!localPort('DeferredWork', 'local DeferredWork = require("infra.deferred_work")') ||
				positions(whole, 'local function defer_tis_call').length !== 1 ||
				positions(whole, 'defer_tis_call =').length ||
				positions(whole, 'local defer_tis_call').length ||
				positions(whole, 'DeferredWork.after =').length ||
				!exact(
					deferred,
					`if type(fn) ~= "function" then return false end
					return DeferredWork.after(TIS_CALL_DELAY, function() pcall(fn) end, "menu_keyboard_layout.tis_call")`
				)
			)
				return false;
			if (section === 'layout_native_record_choice') {
				const choice = body(
					'local function layout_native_choice(caption, selected, ready, callback)'
				);
				const custom = body('local function custom_layout_rows(update_menu, renderer)');
				const active = bodyOf(build, 'local function active_layout_rows()');
				const switching = bodyOf(build, 'local function build_layout_switching_rows()');
				const picker = bodyOf(switching, 'local function picker(current_id, on_pick)');
				if (
					!localPort(
						'set_input_source_async',
						'local set_input_source_async = input_sources.set_input_source_async'
					) ||
					!exact(
						choice,
						`return layout_declared_row("layout_native_record_choice", { layout_native_select = callback }, {
						layout_native_caption = function() return caption end,
						layout_native_selected = function() return selected == true end,
						layout_native_ready = function() return ready == true end,
					})`
					) ||
					!one(
						custom,
						'local ok, LayoutRegistry = pcall(require, "modules.keymap.layout_registry")'
					) ||
					positions(custom, 'LayoutRegistry =').length !== 1 ||
					positions(custom, 'local LayoutRegistry').length ||
					positions(custom, 'LayoutRegistry.select =').length ||
					!one(
						custom,
						`local row = layout_native_choice(type(entry.name) == "string" and entry.name or id, picker.active == id, true, function()
						defer_tis_call(function()
							LayoutRegistry.select(id, function(selected)
								if not selected then pcall(notifications.notify, i18n.get("layout_manager.failure_other"), nil, "error") end
								schedule_menu_refresh(update_menu)
							end)
						end)
					end)`
					) ||
					!one(
						active,
						`local row = layout_native_choice(row_label, r.selected, not r.selected, function()
						defer_tis_call(function()
							set_input_source_async(target_localised, target_kl_name, function()
								schedule_menu_refresh(update_menu)
							end)
						end)
					end)`
					) ||
					!one(
						picker,
						`local row = layout_native_choice(display_for_record(record), current_id == id, true, function()
						local retained = declared_rows()
						if type(retained) ~= "table" or #retained ~= #native_rows + 2 then return false end
						return on_pick(id)
					end)`
					)
				)
					return false;
				for (const [rows, current, field] of [
					['pause_rows', 'cur_pause', 'layout_on_pause'],
					['resume_rows', 'cur_resume', 'layout_on_resume']
				]) {
					if (
						!one(
							switching,
							`${rows} = picker(${current}, function(id)
						if not parents_present() then return false end
						state.${field} = id
						if save_prefs and save_prefs() ~= true then return false end
						if update_menu then update_menu() end
					end)`
						)
					)
						return false;
				}
			} else if (section === 'layout_bundle_update' || section === 'layout_bundle_install') {
				const installed = body(
					'local function build_install_item(scope_label, emoji_install, installed, latest_name, latest_ver, do_install)'
				);
				if (
					!exact(
						installed,
						`local getters = {
					layout_install_scope = function() return scope_label end,
					layout_install_emoji = function() return emoji_install end,
					layout_install_latest = function() return version_str(latest_ver) end,
					layout_install_old = function() return installed and version_str(installed.version) or "" end,
				}
				if installed and not version_gt(latest_ver, installed.version) then
					return layout_declared_row("layout_bundle_installed", {}, getters)
				end
				if installed then return layout_declared_row("layout_bundle_update", { layout_install = do_install }, getters) end
				return layout_declared_row("layout_bundle_install", { layout_install = do_install }, getters)`
					)
				)
					return false;
				for (const [scope, emoji, best] of [
					['system', '🔐', 'system_best'],
					['user', '📥', 'user_best']
				]) {
					if (
						!localPort(
							'install_' + scope,
							'local install_' + scope + ' = install.install_' + scope
						) ||
						!one(
							build,
							`bundle_rows[#bundle_rows + 1] = build_install_item(
							i18n.get("menu.layout.scope_${scope}"), "${emoji}", ${best}, latest, latest_ver,
							function() run_install_and_chain(function() return install_${scope}(bundles_dir, latest) end, legacy_active, update_menu) end
						)`
						)
					)
						return false;
				}
				const chain = body(
					'local function run_install_and_chain(install_fn, legacy_active, update_menu)'
				);
				if (
					positions(whole, 'local function run_install_and_chain').length !== 1 ||
					positions(whole, 'run_install_and_chain =').length ||
					positions(whole, 'local run_install_and_chain').length ||
					!exact(
						chain,
						`local ok = false
						pcall(function() ok = install_fn() end)
						if ok and type(legacy_active) == "table" and #legacy_active > 0 then
							Logger.info(LOG, "Install succeeded — auto-upgrading %d legacy entry(ies) in the active list.", #legacy_active)
							upgrade_active_list_async(legacy_active, function() schedule_menu_refresh(update_menu) end)
							return
						end
						schedule_menu_refresh(update_menu)`
					)
				)
					return false;
			} else if (section === 'layout_bundle_upgrade' || section === 'layout_bundle_upgrade_to') {
				if (
					!localPort(
						'upgrade_active_list_async',
						'local upgrade_active_list_async = input_sources.upgrade_active_list_async'
					) ||
					!one(
						build,
						`bundle_rows[#bundle_rows + 1] = layout_declared_row(legacy_ver and "layout_bundle_upgrade" or "layout_bundle_upgrade_to", {
						layout_upgrade_list = function()
							defer_tis_call(function()
								upgrade_active_list_async(legacy_active, function(ok)
									if ok then pcall(notifications.notify, i18n.get("menu.layout.update_list_ok"), nil, "success") end
									if not ok then pcall(notifications.notify, i18n.get("menu.layout.update_list_fail"), nil, "error") end
									schedule_menu_refresh(update_menu)
								end)
							end)
						end,
					}, {
						layout_bundle_old_version = function() return legacy_ver and version_str(legacy_ver) or "" end,
						layout_bundle_version = function() return target_str end,
					})`
					)
				)
					return false;
			} else if (section === 'layout_bundle_variant_add') {
				if (
					!localPort(
						'enable_keylayout_source_async',
						'local enable_keylayout_source_async = input_sources.enable_keylayout_source_async'
					) ||
					!one(
						build,
						`add_sub[#add_sub + 1] = layout_declared_row("layout_bundle_variant_add", {
						layout_enable_variant = function()
							defer_tis_call(function()
								enable_keylayout_source_async(var.keylayout, label, function(ok)
									if ok then pcall(notifications.notify, string.format(i18n.get("menu.layout.add_ok"), label), nil, "success") end
									if not ok then pcall(notifications.notify, i18n.get("menu.layout.add_fail"), nil, "error") end
									schedule_menu_refresh(update_menu)
								end)
							end)
						end,
					}, {
						layout_variant_label = function() return label end,
						layout_bundle_version = function() return latest_str end,
					})`
					)
				)
					return false;
			} else return false;
		}
	}

	const choice = body('local function layout_native_choice(caption, selected, ready, callback)');
	const install = body(
		'local function build_install_item(scope_label, emoji_install, installed, latest_name, latest_ver, do_install)'
	);
	if (section === 'layout_native_parent')
		return (
			definition.length === 1 &&
			definition[0].type === 'group' &&
			definition[0].id === 'layout_parent_content'
		);
	if (section === 'layout_native_record_choice') {
		const custom = body('local function custom_layout_rows(update_menu, renderer)');
		const active = bodyOf(build, 'local function active_layout_rows()');
		const switching = bodyOf(build, 'local function build_layout_switching_rows()');
		const picker = bodyOf(switching, 'local function picker(current_id, on_pick)');
		return (
			definition.length === 1 &&
			definition[0].type === 'check' &&
			definition[0].id === 'layout_native_select' &&
			definition[0].caption_source === 'native' &&
			require('node:util').isDeepStrictEqual(definition[0].checked_when, [
				'layout_native_selected'
			]) &&
			require('node:util').isDeepStrictEqual(definition[0].disabled_when, [
				'layout_native_ready'
			]) &&
			ordered(choice, [
				'return layout_declared_row("layout_native_record_choice", { layout_native_select = callback }, {',
				'layout_native_caption = function() return caption end',
				'layout_native_selected = function() return selected == true end',
				'layout_native_ready = function() return ready == true end'
			]) &&
			one(
				custom,
				'local row = layout_native_choice(type(entry.name) == "string" and entry.name or id, picker.active == id, true, function()'
			) &&
			ordered(custom, [
				'local row = layout_native_choice(type(entry.name) == "string" and entry.name or id, picker.active == id, true, function()',
				'rows[#rows + 1] = row'
			]) &&
			positions(custom, 'return rows').filter((at) => custom.scopes[at] === 0).length === 1 &&
			ordered(active, [
				'local row = layout_native_choice(row_label, r.selected, not r.selected, function()',
				'rows[#rows + 1] = row'
			]) &&
			positions(active, 'return rows').filter((at) => active.scopes[at] === 0).length === 1 &&
			ordered(picker, [
				'local row = layout_native_choice(display_for_record(record), current_id == id, true, function()',
				'native_rows[#native_rows + 1] = row',
				'local rows = declared_rows()'
			]) &&
			positions(picker, 'return rows').filter((at) => picker.scopes[at] === 0).length === 1
		);
	}
	const installKinds = {
		layout_bundle_installed: 'label',
		layout_bundle_update: 'command',
		layout_bundle_install: 'command'
	};
	if (Object.hasOwn(installKinds, section)) {
		if (
			definition.length !== 1 ||
			definition[0].type !== installKinds[section] ||
			definition[0].id !==
				(section === 'layout_bundle_installed' ? 'layout_installed_caption' : 'layout_install')
		)
			return false;
		const command = installKinds[section] === 'label' ? '{}' : '{ layout_install = do_install }';
		return (
			one(install, 'return layout_declared_row("' + section + '", ' + command + ', getters)') &&
			[
				'layout_install_scope',
				'layout_install_emoji',
				'layout_install_latest',
				'layout_install_old'
			].every((key) => positions(install, key + ' = function()').length === 1) &&
			positions(build, 'build_install_item(').length === 2
		);
	}
	if (section === 'layout_bundle_frame')
		return ordered(build, [
			'local function system_provider() return latest and {bundle_rows[1]} or {} end',
			'local function user_provider() return latest and {bundle_rows[2]} or {} end',
			'local function status_provider() return {bundle_rows[#bundle_rows]} end',
			'local rows = ManifestMenu.template_rows("layout_bundle_frame", {}, {}, {',
			'layout_bundle_system = system_provider',
			'layout_bundle_user = user_provider',
			'layout_bundle_status = status_provider',
			'if type(rows) ~= "table" or #rows ~= #bundle_rows then return nil end'
		]);
	const kinds = {
		layout_bundle_in_list: ['label', 'layout_in_list_caption'],
		layout_bundle_update_install_first: ['label', 'layout_update_install_first_caption'],
		layout_bundle_upgrade: ['command', 'layout_upgrade_list'],
		layout_bundle_upgrade_to: ['command', 'layout_upgrade_list'],
		layout_bundle_variant_added: ['label', 'layout_added_variant_caption'],
		layout_bundle_variant_add: ['command', 'layout_enable_variant'],
		layout_bundle_variant_parent: ['group', 'layout_variant_choices'],
		layout_bundle_install_first: ['label', 'layout_install_first_caption']
	};
	const kind = kinds[section];
	if (
		!kind ||
		definition.length !== 1 ||
		definition[0].type !== kind[0] ||
		definition[0].id !== kind[1]
	)
		return false;
	if (section === 'layout_bundle_upgrade' || section === 'layout_bundle_upgrade_to')
		return (
			one(
				build,
				'layout_declared_row(legacy_ver and "layout_bundle_upgrade" or "layout_bundle_upgrade_to", {'
			) &&
			one(build, 'layout_upgrade_list = function()') &&
			one(build, 'upgrade_active_list_async(legacy_active, function(ok)')
		);
	if (!one(build, 'layout_declared_row("' + section + '", {')) return false;
	if (section === 'layout_bundle_variant_add')
		return (
			one(build, 'layout_enable_variant = function()') &&
			one(build, 'enable_keylayout_source_async(var.keylayout, label,')
		);
	if (section === 'layout_bundle_variant_parent')
		return ordered(build, [
			'local function variant_provider() return add_sub end',
			'layout_declared_row("layout_bundle_variant_parent", {}, {',
			'{ layout_variant_choices = variant_provider }'
		]);
	return true;
}

/** Exact canonical row ownership through the actual finite Layout publication route. */
function nativeLayoutRowOwnership(
	source,
	extension,
	platform,
	section,
	row,
	definition,
	captionFormat,
	ownership
) {
	if (
		typeof source !== 'string' ||
		!source.includes('layout_declared_row') ||
		extension !== '.lua' ||
		platform !== 'hs' ||
		!['behavior', 'inert'].includes(ownership) ||
		!Array.isArray(definition) ||
		definition.length !== 1 ||
		definition[0] !== row ||
		!row ||
		typeof row !== 'object' ||
		Array.isArray(row) ||
		!Array.isArray(row.platforms) ||
		row.platforms.length !== 1 ||
		row.platforms[0] !== platform ||
		row.unavailable !== 'hide' ||
		typeof row.id !== 'string' ||
		row.id === '' ||
		typeof captionFormat !== 'function' ||
		['command', 'action', 'callback', 'handler', 'provider'].some((field) =>
			Object.hasOwn(row, field)
		) ||
		!(ownership === 'behavior'
			? ['command', 'check'].includes(row.type)
			: ['label', 'section_header'].includes(row.type))
	)
		return false;
	const fields =
		ownership === 'inert'
			? ['type', 'id', 'i18n', 'platforms', 'unavailable', 'caption_getter', 'caption_getters']
			: [
					'type',
					'id',
					'i18n',
					'platforms',
					'unavailable',
					'caption_getter',
					'caption_getters',
					'caption_source',
					'checked_when',
					'disabled_when'
				];
	if (
		Object.keys(row).some((field) => !fields.includes(field)) ||
		(row.type === 'command' &&
			(Object.hasOwn(row, 'checked_when') || Object.hasOwn(row, 'disabled_when')))
	)
		return false;
	try {
		require('./menu-row-availability.cjs').validateChildTemplates(
			{ [section]: definition },
			captionFormat
		);
	} catch {
		return false;
	}
	return nativeLayoutTemplatePublication(source, section, definition, ownership);
}

module.exports = { nativeLayoutTemplatePublication, nativeLayoutRowOwnership };
