// Finite source evidence for the two real personal-information editor leaves.
// This proves only the guarded helper and direct receiving chain, never runtime authority.
'use strict';
const { scriptTokens } = require('./script-source.cjs');

const HELPER_BODY = `
	local modules = rawget(package, "loaded")
	local renderer = ManifestMenu
	if type(modules) ~= "table" or rawget(modules, "infra.manifest_menu") ~= renderer
		or type(renderer) ~= "table" or getmetatable(renderer) ~= nil then return nil end
	local template, root_owner, array_owner = rawget(renderer, "template_rows"),
		rawget(renderer, "get_root"), rawget(renderer, "get_array")
	if type(template) ~= "function" or type(root_owner) ~= "function" or type(array_owner) ~= "function" then return nil end
	local function facade_current()
		return rawget(package, "loaded") == modules and rawget(modules, "infra.manifest_menu") == renderer
			and getmetatable(renderer) == nil and rawget(renderer, "template_rows") == template
			and rawget(renderer, "get_root") == root_owner and rawget(renderer, "get_array") == array_owner
	end
	local root, source = root_owner(), array_owner("personal_info_editor_frame")
	if not facade_current() or type(root) ~= "table" or getmetatable(root) ~= nil
		or type(source) ~= "table" or getmetatable(source) ~= nil
		or rawget(root, "personal_info_editor_frame") ~= source or rawget(source, 1) == nil then return nil end
	for index in next, source do if index ~= 1 then return nil end end
	local declaration = rawget(source, 1)
	if type(declaration) ~= "table" or getmetatable(declaration) ~= nil
		or rawget(declaration, "type") ~= "command" or rawget(declaration, "id") ~= "personal_info_editor_open"
		or type(rawget(declaration, "i18n")) ~= "string" or rawget(declaration, "i18n") == ""
		or rawget(declaration, "unavailable") ~= "hide" then return nil end
	local allowed = { type = true, id = true, i18n = true, platforms = true, unavailable = true }
	local fields, count = {}, 0
	for key, value in next, declaration do
		if not allowed[key] then return nil end
		fields[key], count = value, count + 1
	end
	if count ~= 5 then return nil end
	local platforms = rawget(declaration, "platforms")
	if type(platforms) ~= "table" or getmetatable(platforms) ~= nil
		or rawget(platforms, 1) ~= "hs" or rawget(platforms, 2) ~= "linux" then return nil end
	for index in next, platforms do if index ~= 1 and index ~= 2 then return nil end end
	local function current()
		if not facade_current() then return false end
		if root_owner() ~= root or array_owner("personal_info_editor_frame") ~= source or not facade_current()
			or getmetatable(root) ~= nil or rawget(root, "personal_info_editor_frame") ~= source
			or getmetatable(source) ~= nil or rawget(source, 1) ~= declaration
			or getmetatable(declaration) ~= nil or getmetatable(platforms) ~= nil then return false end
		for index in next, source do if index ~= 1 then return false end end
		local actual_count = 0
		for key, value in next, declaration do
			if fields[key] ~= value then return false end
			actual_count = actual_count + 1
		end
		if actual_count ~= count then return false end
		for index in next, platforms do if index ~= 1 and index ~= 2 then return false end end
		return rawget(platforms, 1) == "hs" and rawget(platforms, 2) == "linux"
	end
	if not current() then return nil end
	return current, template`;
const MAC_BODY = `
	if not ctx.personal_info then return nil end
	description = ctx.applyTriggerChar(description)
	local items = {
		{
			label   = description,
			checked = ctx.state.personal_info or nil,
			action      = function()
				ctx.state.personal_info = not ctx.state.personal_info
				if ctx.state.personal_info then
					if type(ctx.personal_info.enable) == "function" then pcall(ctx.personal_info.enable) end
				else
					if type(ctx.personal_info.disable) == "function" then pcall(ctx.personal_info.disable) end
				end
				if ctx.save_prefs() ~= true then return false end
				ctx.notify_feature(description or i18n.get("notify.personal_info"), ctx.state.personal_info)
				ctx.updateMenu()
			end,
		},
	}
	local current, template = personal_info_editor_source()
	if not current then return items end
	local editor = template("personal_info_editor_frame", {
		personal_info_editor_open = function()
			if not current() then return false end
			return DeferredWork.after(0.1,
				function()
					if not current() then return false end
					pcall(ctx.personal_info.open_editor)
				end,
				"menu_hotstrings.open_personal_info")
		end,
	}, {}, {})
	if not current() or type(editor) ~= "table" or getmetatable(editor) ~= nil then return items end
	for index in next, editor do if index ~= 1 then return items end end
	local row = rawget(editor, 1)
	if type(row) ~= "table" or getmetatable(row) ~= nil or type(rawget(row, "label")) ~= "string"
		or rawget(row, "label") == "" or type(rawget(row, "action")) ~= "function"
		or rawget(row, "disabled") ~= nil then return items end
	for key in next, row do if key ~= "label" and key ~= "action" then return items end end
	items[#items + 1] = row
	return items`;
const LINUX_BODY = `
			local rows = {}
			-- Its own handler, not append_class. This driver's group list comes from
			-- TOML file stems and there is no dynamic-hotstrings TOML — the rules are
			-- registered in code — so append_class matched nothing and the row
			-- resolved to a greyed "(aucun groupe chargé)" while the engine was
			-- running and expanding dates and @-tags. A user could not see the
			-- category, count it, or switch it off.
			local dyn = ctx.dyn_hotstrings
			if type(dyn) ~= "table" or type(dyn.is_enabled) ~= "function" then
				Logger.error(LOG, "No dynamic-hotstrings manager in the menu context — its category is not shown.")
				return rows
			end

			local on = dyn.is_enabled()
			-- active_count, not get_rules_count: the latter counts the RULES the
			-- dynamic engine registered and knows nothing about the prefix
			-- expansions, which are mappings held by the ordinary matcher. The
			-- category would have advertised 3 while offering 13, and would not have
			-- moved when a family was switched off.
			local count = type(dyn.active_count) == "function" and dyn.active_count() or 0
			if on and type(dyn.user_code_is_enabled) == "function" and dyn.user_code_is_enabled() then
				count = count + dyn.user_code_count()
			end

			local sub = {}
			local current, template = personal_info_editor_source()
			if current then
				local editor = template("personal_info_editor_frame", {
					personal_info_editor_open = function()
						if not current() then return false end
						if type(ctx.webview) ~= "table" or type(ctx.webview.show) ~= "function" then
							Logger.error(LOG, "Personal-info editor cannot open: webview manager is unavailable.")
							return
						end
						ctx.webview.show("personal_info_editor")
					end,
				}, {}, {})
				local valid = current() and type(editor) == "table" and getmetatable(editor) == nil
				if valid then for index in next, editor do if index ~= 1 then valid = false end end end
				local row = valid and rawget(editor, 1) or nil
				valid = type(row) == "table" and getmetatable(row) == nil
					and type(rawget(row, "label")) == "string" and rawget(row, "label") ~= ""
					and type(rawget(row, "action")) == "function" and rawget(row, "disabled") == nil
				if valid then for key in next, row do if key ~= "label" and key ~= "action" then valid = false end end end
				if valid then sub[1] = row end
			end

			-- One row per rule family, as Windows and macOS offer. The plan recorded
			-- this as blocked by the shared engine "registering the date rules as a
			-- batch with no identifier". That was wrong: add_rule has always carried
			-- a section, and match_buffer has always taken a predicate to filter on
			-- it. This driver simply passed nil for it.
			local families = type(dyn.rule_families) == "function" and dyn.rule_families() or {}
			if #families > 0 then
				-- The existing shared boundary is the only admitted inert entry.
				if type(boundaries) ~= "table" or getmetatable(boundaries) ~= nil or #boundaries ~= 1
					or type(boundaries[1]) ~= "table" or getmetatable(boundaries[1]) ~= nil
					or boundaries[1].separator ~= true then
					Logger.error(LOG, "Declared dynamic hotstring section boundary unavailable.")
					return rows
				end
				for index in next, boundaries do if index ~= 1 then return rows end end
				for key in next, boundaries[1] do if key ~= "separator" then return rows end end
				sub[#sub + 1] = boundaries[1]

				for _, family in ipairs(families) do
					if family.separator then
						sub[#sub + 1] = boundaries[1]
					else
						local section, enabled, family_id = family.section, family.enabled, family.id
						-- The count, on the families that have one. A prefix family with
						-- 0 behind it is a switch that can do nothing until the user
						-- fills in that field of personal_info.toml, and the count is
						-- the only thing on the row that says so.
						local family_label = family.count
							and string.format("%s (%d)", family.label, family.count)
							or family.label
						sub[#sub + 1] = {
							-- Resolved by the manager, which owns both the locale key
							-- and the engine that answers what "{date}" is today.
							label    = family_label,
							checked  = enabled,
							-- Greyed while the category itself is off, like a section
							-- row: the tick still says what comes back when it is
							-- switched on.
							disabled = not on,
							action       = function()
								local current_family
								local called, committed = pcall(function()
									local current = ctx.dyn_hotstrings
									if current ~= dyn or type(current.is_enabled) ~= "function"
										or type(current.rule_families) ~= "function"
										or type(current.is_rule_enabled) ~= "function"
										or type(current.set_rule_enabled) ~= "function" then return false end
									local declared = 0
									for _, entry in ipairs(ManifestMenu.get_dynamic_hotstring_families()) do
										if entry.id == family_id and (entry.linux_section or entry.section) == section then
											declared = declared + 1
										end
									end
									if declared ~= 1 then return false end
									for _, entry in ipairs(current.rule_families()) do
										if entry.id == family_id and entry.section == section then
											if current_family ~= nil then return false end
											current_family = entry
										end
									end
									if type(current_family) ~= "table" or type(current_family.enabled) ~= "boolean"
										or current.is_enabled() ~= true then return false end
									local live_enabled = current.is_rule_enabled(nil, section)
									if type(live_enabled) ~= "boolean" or live_enabled ~= current_family.enabled
										or ctx.dyn_hotstrings ~= current then return false end
									return current.set_rule_enabled(section, not live_enabled)
								end)
								if not called or committed ~= true then
									Logger.error(LOG, "Dynamic hotstring family refused (%s).", called and "owner-not-committed" or "owner-error")
									show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
									return false
								end
								-- A prefix family is matched by the ORDINARY engine, which
								-- knows nothing about dynamic families — so its switch has
								-- to add or remove mappings rather than filter them, and
								-- that means a reload. The date families need none of this;
								-- their guard is read at match time.
								-- The preference receipt above does not acknowledge this
								-- separate catalogue reload or invent its compensation.
								if current_family.count and config and type(config.reload) == "function" then
									config.reload()
								end
								if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
								return true
							end,
						}
					end
				end
			end

			local programmable = ProgrammableMenuPolicy.build_entry_rows(ManifestMenu,
				function() return ProgrammableHotstrings.build(ctx) end)
			for _, row in ipairs(programmable) do sub[#sub + 1] = row end

			local function commit_scope(enabled)
				local called, committed = pcall(function() return dyn.set_scope_enabled(enabled, config) end)
				if not called or committed ~= true then
					Logger.error(LOG, "Dynamic hotstring scope refused (%s).", called and "owner-not-committed" or "owner-error")
					show_error(i18n_safe("dialog.bulk_toggle.save_failed"), i18n_safe("common.error_title"))
					return false
				end
				if type(ctx.on_menu_changed) == "function" then ctx.on_menu_changed() end
				return true
			end
			local rendered = ManifestMenu.build("hotstring_category_menu", "Hotstrings", nil, nil,
				{ commands = {
					hotstring_category_enable_all = function() return commit_scope(true) end,
					hotstring_category_disable_all = function() return commit_scope(false) end,
				} }, {
					hotstring_category_file = function() return {} end,
					hotstring_category_sections = function() return sub end,
				})

			rows[#rows + 1] = {
				-- category.dynamic_hotstrings, which is the key the CATEGORY carries in
				-- all 21 locales. menu.hotstrings.dynamic is the manifest's SECTION
				-- description key and has no translation of its own, so it would have
				-- rendered as the raw string.
				label   = string.format("%s (%d)", i18n_safe("category.dynamic_hotstrings"), count),
				checked = on,
				submenu = rendered,
			}
			return rows`;

// Only this pre-existing extension-owned chunk may receive its own sandbox.
const EXTENSION_SANDBOX_BODY =
	'\tlocal rows = {}\n\n\tlocal ok_paths, Paths = pcall(require, "infra.paths")\n\tlocal ok_loader, Loader = pcall(require, "modules.hotstrings.loader")\n\tif not ok_paths or not ok_loader or type(Paths.extension_roots) ~= "function" then return rows end\n\n\t-- The same io functions hotstrings_config.extension_packs() injects. The\n\t-- scanner takes them rather than reaching for the filesystem itself, which is\n\t-- what lets it be shared and tested; passing nil returns an empty list, so\n\t-- this is not optional.\n\tlocal ok_scan, packs = pcall(Extensions.scan, Paths.extension_roots(), {\n\t\tlist_dirs  = Loader.list_subdirs,\n\t\tlist_files = Loader.find_toml_files,\n\t\tread_file  = Loader.read_file,\n\t})\n\tif not ok_scan or type(packs) ~= "table" then return rows end\n\n\t-- One entry per extension: the scanner already collapses an id that appears\n\t-- under more than one root (bundled and user-installed).\n\tfor _, pack in ipairs(packs) do\n\t\tlocal id, dir = pack.id, pack.dir\n\t\tif id and dir then\n\t\t\tlocal menu_path = dir .. "/shortcuts/menu.lua"\n\t\t\tlocal chunk = loadfile(menu_path)\n\t\t\tif chunk then\n\t\t\t\tlocal collected = {}\n\t\t\t\tlocal sandbox = {\n\t\t\t\t\tadd_item = function(item)\n\t\t\t\t\t\tif type(item) == "table" then collected[#collected + 1] = item end\n\t\t\t\t\tend,\n\t\t\t\t\tt        = i18n_safe,\n\t\t\t\t\text_name = pack.name or id,\n\t\t\t\t}\n\t\t\t\tsetmetatable(sandbox, { __index = _G })\n\t\t\t\tsandbox._G = sandbox\n\n\t\t\t\tif setfenv then setfenv(chunk, sandbox) end\n\t\t\t\tlocal ok_run, err = pcall(chunk)\n\t\t\t\tif not ok_run then\n\t\t\t\t\t-- Surfaced as a row, not only logged: an extension whose menu\n\t\t\t\t\t-- throws would otherwise be indistinguishable from one that\n\t\t\t\t\t-- declares nothing, and its author would have no way to tell.\n\t\t\t\t\tLogger.warn(LOG, "Extension \'%s\' shortcuts/menu.lua failed: %s", id, tostring(err))\n\t\t\t\t\tlocal marker_rows = ManifestMenu.template_rows("shortcut_extension_error_frame", {}, {\n\t\t\t\t\t\tshortcut_extension_name = function() return pack.name or id end,\n\t\t\t\t\t}, {})\n\t\t\t\t\tif not marker_rows or #marker_rows == 0 then return {} end\n\t\t\t\t\tfor _, row in ipairs(marker_rows) do rows[#rows + 1] = row end\n\t\t\t\telseif #collected > 0 then\n\t\t\t\t\t-- The extension\'s OWN rows are still adapted: an author writes\n\t\t\t\t\t-- them in the host dialect both Lua drivers expose (`add_item`\n\t\t\t\t\t-- with `title`/`fn`), and that is a published surface. This row —\n\t\t\t\t\t-- the pack\'s own entry — is ours, so it is provider data.\n\t\t\t\t\tlocal external_rows = _as_provider_row_list(collected)\n\t\t\t\t\tif external_rows then rows[#rows + 1] = { label = pack.name or id, items = external_rows } end\n\t\t\t\tend\n\t\t\tend\n\t\tend\n\tend\n\n\treturn rows';

function lex(source, base = 0) {
	if (typeof source !== 'string') return null;
	const tokens = scriptTokens(source, '.lua'),
		stack = [],
		scopes = [],
		closes = new Map(),
		fields = [],
		tables = [],
		depth = [];
	let awaitingDo = 0;
	for (let at = 0; at < tokens.length; at++) {
		scopes[at] = stack.length;
		const functionDepth = stack.filter((block) => block.word === 'function').length;
		depth[at] = functionDepth;
		fields[at] = tables.at(-1)?.functionDepth === functionDepth;
		const token = tokens[at];
		if (token.kind === 'symbol' && token.value === '{') tables.push({ functionDepth });
		if (token.kind === 'symbol' && token.value === '}') tables.pop();
		const afterLabel =
			tokens[at - 1]?.value === ':' &&
			tokens[at - 2]?.value === ':' &&
			tokens[at - 3]?.kind === 'identifier' &&
			tokens[at - 4]?.value === ':' &&
			tokens[at - 5]?.value === ':';
		if (token.kind !== 'identifier' || (['.', ':'].includes(tokens[at - 1]?.value) && !afterLabel))
			continue;
		if (['function', 'if', 'for', 'while', 'repeat'].includes(token.value)) {
			stack.push({ word: token.value, at });
			if (['for', 'while'].includes(token.value)) awaitingDo++;
		} else if (token.value === 'do') {
			if (awaitingDo) awaitingDo--;
			else stack.push({ word: 'do', at });
		} else if (token.value === 'end' || token.value === 'until') {
			const block = stack.pop();
			if (!block || (token.value === 'until') !== (block.word === 'repeat')) return null;
			closes.set(block.at, at);
		}
	}
	return stack.length ? null : { source, base, tokens, scopes, closes, fields, depth };
}
function positions(unit, statement, root = false, functionDepth) {
	if (!unit) return [];
	const wanted = scriptTokens(statement, '.lua'),
		found = [];
	for (let at = 0; at < unit.tokens.length; at++) {
		if (functionDepth !== undefined && unit.depth[at] !== functionDepth) continue;
		if ((root && unit.scopes[at] !== 0) || ['.', ':'].includes(unit.tokens[at - 1]?.value))
			continue;
		if (
			wanted.every(
				(token, n) =>
					unit.tokens[at + n]?.kind === token.kind &&
					unit.tokens[at + n]?.value === token.value &&
					(token.kind !== 'string' ||
						unit.source.slice(unit.tokens[at + n].start, unit.tokens[at + n].end) ===
							statement.slice(token.start, token.end))
			)
		)
			found.push(at);
	}
	return found;
}
function owner(unit, signature, root = false) {
	const found = positions(unit, signature, root);
	if (found.length !== 1) return null;
	const at = found[0],
		count = scriptTokens(signature, '.lua').length;
	const functionAt = unit.tokens.findIndex(
		(token, n) => n >= at && n < at + count && token.value === 'function'
	);
	const end = unit.closes.get(functionAt);
	if (end === undefined) return null;
	const startOffset = unit.tokens[at + count - 1].end;
	return lex(unit.source.slice(startOffset, unit.tokens[end].start), unit.base + startOffset);
}
function equal(unit, source) {
	const wanted = scriptTokens(source, '.lua');
	return (
		!!unit &&
		unit.tokens.length === wanted.length &&
		wanted.every(
			(token, n) =>
				unit.tokens[n].kind === token.kind &&
				unit.tokens[n].value === token.value &&
				(token.kind !== 'string' ||
					unit.source.slice(unit.tokens[n].start, unit.tokens[n].end) ===
						source.slice(token.start, token.end))
		)
	);
}

/** Direct lexical namespace writes/shadows are refused; this is not a transitive graph claim. */
function namespaceCurrent(unit, allowedManifest, sandboxCalls) {
	const protectedNames = new Set([
		'ManifestMenu',
		'package',
		'rawget',
		'getmetatable',
		'type',
		'next',
		'ipairs',
		'pairs',
		'require',
		'pcall',
		'DeferredWork',
		'setfenv',
		'loadfile',
		'_G',
		'_ENV'
	]);
	const t = unit.tokens;
	const keywords = new Set([
		'and',
		'break',
		'do',
		'else',
		'elseif',
		'end',
		'false',
		'for',
		'function',
		'goto',
		'if',
		'in',
		'local',
		'nil',
		'not',
		'or',
		'repeat',
		'return',
		'then',
		'true',
		'until',
		'while'
	]);
	// Match complete Lua target lists; quoted delimiters stay data.
	const symbol = (at, value) => t[at]?.kind === 'symbol' && t[at].value === value;
	const balancedEnd = (start) => {
		const closing = { '(': ')', '[': ']', '{': '}' },
			stack = [];
		for (let at = start; at < t.length; at++) {
			if (t[at].kind !== 'symbol') continue;
			if (closing[t[at].value]) stack.push(closing[t[at].value]);
			else if ([')', ']', '}'].includes(t[at].value)) {
				if (stack.pop() !== t[at].value) return null;
				if (stack.length === 0) return at + 1;
			}
		}
		return null;
	};
	// A grouped canonical root is only a bare name and balanced parentheses.
	// No conditional expression, function result or alias receives root credit.
	const groupedRootEnd = (start, names) => {
		let at = start,
			groups = 0;
		while (symbol(at, '(')) {
			groups++;
			at++;
		}
		if (t[at]?.kind !== 'identifier' || !names.has(t[at].value)) return null;
		at++;
		while (groups > 0) {
			if (!symbol(at, ')')) return null;
			groups--;
			at++;
		}
		return at;
	};
	const lvalueEnd = (start) => {
		let at = start,
			assignable = false;
		if (t[at]?.kind === 'identifier' && !keywords.has(t[at].value)) {
			at++;
			assignable = true;
		} else if (symbol(at, '(')) at = balancedEnd(at);
		else return null;
		if (at === null) return null;
		while (at < t.length) {
			if (symbol(at, '.')) {
				if (t[at + 1]?.kind !== 'identifier' || keywords.has(t[at + 1].value)) return null;
				at += 2;
				assignable = true;
			} else if (symbol(at, '[')) {
				at = balancedEnd(at);
				if (at === null) return null;
				assignable = true;
			} else if (symbol(at, '(') || symbol(at, '{')) {
				at = balancedEnd(at);
				if (at === null) return null;
				assignable = false;
			} else if (t[at]?.kind === 'string') {
				at++;
				assignable = false;
			} else if (symbol(at, ':')) {
				if (t[at + 1]?.kind !== 'identifier' || keywords.has(t[at + 1].value)) return null;
				at += 2;
				if (symbol(at, '(') || symbol(at, '{')) at = balancedEnd(at);
				else if (t[at]?.kind === 'string') at++;
				else return null;
				if (at === null) return null;
				assignable = false;
			} else break;
		}
		return assignable ? at : null;
	};
	const assignmentAfter = (start) => {
		let after = lvalueEnd(start);
		if (after === null) return false;
		while (symbol(after, ',')) {
			after = lvalueEnd(after + 1);
			if (after === null) return false;
		}
		return symbol(after, '=') && !symbol(after + 1, '=');
	};
	const canonicalRoots = new Set(['package', 'ManifestMenu', '_G', '_ENV']);
	const referencesRoot = (start, end) => {
		for (let at = start; at < end; at++) {
			if (
				t[at].kind === 'identifier' &&
				canonicalRoots.has(t[at].value) &&
				!symbol(at - 1, '.') &&
				!symbol(at - 1, ':')
			)
				return true;
		}
		return false;
	};
	const firstArgumentEnd = (start) => {
		for (let at = start; at < t.length; at++) {
			if (['(', '[', '{'].some((value) => symbol(at, value))) {
				const end = balancedEnd(at);
				if (end === null) return null;
				at = end - 1;
			} else if (t[at].kind === 'identifier' && t[at].value === 'function') {
				const end = unit.closes.get(at);
				if (end === undefined) return null;
				at = end;
			} else if (symbol(at, ',') || symbol(at, ')')) return at;
		}
		return null;
	};
	// A namespace-bearing expression is unproved: refuse its direct outer
	// lvalue, rather than lending canonical root credit to its expression.
	for (let opening = 0; opening < t.length; opening++) {
		if (!symbol(opening, '(') || !assignmentAfter(opening)) continue;
		const prefix = t[opening - 1];
		if (
			(prefix?.kind === 'identifier' && !keywords.has(prefix.value)) ||
			symbol(opening - 1, ')') ||
			symbol(opening - 1, ']')
		)
			continue;
		const end = balancedEnd(opening);
		if (end !== null && referencesRoot(opening + 1, end - 1)) return false;
	}
	for (let at = 0; at < t.length; at++) {
		if (t[at].kind !== 'identifier') continue;
		if (t[at].value === 'function') {
			if (t[at + 1]?.kind === 'identifier' && protectedNames.has(t[at + 1].value)) return false;
			let p = at + 1;
			while (p < t.length && t[p].value !== '(') p++;
			for (p++; p < t.length && t[p].value !== ')'; p++)
				if (t[p].kind === 'identifier' && protectedNames.has(t[p].value)) return false;
		}
		if (t[at].value === 'local' || t[at].value === 'for') {
			let p = at + 1;
			if (t[p]?.value === 'function') p++;
			while (t[p]?.kind === 'identifier') {
				if (protectedNames.has(t[p].value) && !allowedManifest.has(p)) return false;
				if (t[p + 1]?.value !== ',') break;
				p += 2;
			}
		}
		if (
			t[at].value === 'setfenv' &&
			t[at + 1]?.value === '(' &&
			!sandboxCalls.has(unit.base + t[at].start)
		)
			return false;
		if (
			t[at].value === 'rawset' &&
			t[at + 1]?.value === '(' &&
			['package', 'ManifestMenu', '_G', '_ENV'].includes(t[at + 2]?.value)
		)
			return false;
		if (
			t[at].value === 'setmetatable' &&
			t[at + 1]?.value === '(' &&
			['package', 'ManifestMenu', '_G', '_ENV'].includes(t[at + 2]?.value)
		)
			return false;
		if (['rawset', 'setmetatable'].includes(t[at].value) && symbol(at + 1, '(')) {
			const argumentEnd = firstArgumentEnd(at + 2);
			if (argumentEnd === null || referencesRoot(at + 2, argumentEnd)) return false;
			const targetEnd = groupedRootEnd(at + 2, new Set(['package', 'ManifestMenu', '_G', '_ENV']));
			if (targetEnd !== null && symbol(targetEnd, ',')) return false;
		}
		// Immediate constructor fields/values are data reads at the constructor's
		// creation function depth. Nested callbacks keep real namespace writes.
		// Direct mutating primitive calls above are still refused in data expressions.
		if (unit.fields[at]) continue;
		if (
			!protectedNames.has(t[at].value) &&
			!(t[at - 2]?.value === '_G' && t[at - 1]?.value === '.')
		)
			continue;
		if (['.', ':'].includes(t[at - 1]?.value) && t[at - 2]?.value !== '_G') continue;
		let target = at;
		while (symbol(target - 1, '(') && groupedRootEnd(target - 1, new Set([t[at].value])) !== null) {
			const prefix = t[target - 2];
			// Do not mistake a function's argument parentheses for a grouped root.
			if (
				(prefix?.kind === 'identifier' && !keywords.has(prefix.value)) ||
				symbol(target - 2, ')') ||
				symbol(target - 2, ']')
			)
				break;
			target--;
		}
		if (assignmentAfter(target) && !allowedManifest.has(at)) return false;
	}
	return true;
}

/** Owns the sole existing separate-chunk environment call, never the receiving environment. */
function extensionSandboxCallOffset(whole) {
	const extension = owner(whole, 'local function _extension_shortcut_rows()', true);
	if (!equal(extension, EXTENSION_SANDBOX_BODY)) return -1;
	const calls = positions(extension, 'if setfenv then setfenv(chunk, sandbox) end');
	if (calls.length !== 1) return -1;
	return extension.base + extension.tokens[calls[0] + 3].start;
}

/** Returns physical offsets only after the complete direct helper/receiving grammar is owned. */
function personalInfoEvidence(source) {
	const whole = lex(source);
	if (!whole) return null;
	const helper = owner(whole, 'local function personal_info_editor_source()', true);
	if (!equal(helper, HELPER_BODY)) return null;
	let platform, consumer;
	const mac = owner(whole, 'local function buildPersonalInfoItems(ctx, description)', true);
	if (equal(mac, MAC_BODY)) {
		platform = 'hs';
		consumer = mac;
	} else {
		const outer = owner(whole, 'local function _manifest_hotstring_rows(ctx, config)', true);
		consumer = owner(outer, '["hotstring_categories_dynamic"] = function()');
		if (!consumer || !equal(consumer, LINUX_BODY)) return null;
		platform = 'linux';
	}
	const importStatement =
		platform === 'hs'
			? 'local ManifestMenu = require("infra.manifest_menu")'
			: 'local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")';
	const imports = positions(whole, importStatement, true);
	if (imports.length !== 1 || whole.tokens[imports[0]].start >= helper.base) return null;
	const allowed = new Set([imports[0] + (platform === 'hs' ? 1 : 3)]);
	if (platform === 'linux') {
		const fallback = positions(
			whole,
			'if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end',
			true
		);
		if (fallback.length !== 1) return null;
		const wanted = scriptTokens(
			'if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end',
			'.lua'
		);
		allowed.add(
			fallback[0] +
				wanted.findIndex(
					(token, n) => token.value === 'ManifestMenu' && wanted[n + 1]?.value === '='
				)
		);
	}
	// The Mac scheduling owner is the actual imported DeferredWork, with no replacement.
	if (platform === 'hs') {
		const deferred = positions(whole, 'local DeferredWork = require("infra.deferred_work")', true);
		if (deferred.length !== 1 || whole.tokens[deferred[0]].start >= consumer.base) return null;
		allowed.add(deferred[0] + 1);
	}
	const sandboxOffset = platform === 'linux' ? extensionSandboxCallOffset(whole) : -1;
	if (!namespaceCurrent(whole, allowed, new Set(sandboxOffset < 0 ? [] : [sandboxOffset])))
		return null;
	const calls = positions(
		consumer,
		'local current, template = personal_info_editor_source()',
		true
	);
	const templates = positions(consumer, 'local editor = template("personal_info_editor_frame", {');
	if (
		calls.length !== 1 ||
		templates.length !== 1 ||
		helper.base >= consumer.base ||
		consumer.tokens[calls[0]].start >= consumer.tokens[templates[0]].start
	)
		return null;
	const producerName = platform === 'hs' ? 'buildPersonalInfoItems' : '_manifest_hotstring_rows';
	if (
		whole.tokens.filter((token) => token.kind === 'identifier' && token.value === producerName)
			.length !== 2 ||
		positions(
			whole,
			platform === 'hs'
				? 'local pi_items = buildPersonalInfoItems(ctx, desc)'
				: 'local items = _manifest_hotstring_rows(ctx, config)'
		).length !== 1
	)
		return null;
	if (platform === 'hs') {
		const caller = owner(whole, 'function M.build_groups(ctx, only, counts)', true);
		const receiving = `local pi_items = buildPersonalInfoItems(ctx, desc)
			if pi_items then
				for _, pi in ipairs(pi_items) do sec_menu[#sec_menu + 1] = pi end
				prev_was_sep = false
			end`;
		if (
			!caller ||
			caller.base <= consumer.base ||
			positions(caller, receiving, false, 0).length !== 1
		)
			return null;
	} else {
		const caller = owner(whole, 'local function _build_hotstrings(ctx)', true);
		if (
			!caller ||
			positions(caller, 'local items = _manifest_hotstring_rows(ctx, config)', true).length !== 1 ||
			positions(
				caller,
				'return receive(items, { hotstrings_enabled = function() return _hotstrings_on(ctx) end, hotstrings_parent_total = function() return grand_total end, hotstrings_parent_count_present = function() return true end })',
				true
			).length !== 1
		)
			return null;
	}
	const helperReferences = whole.tokens.filter(
		(token) => token.kind === 'identifier' && token.value === 'personal_info_editor_source'
	);
	if (helperReferences.length !== 2) return null;
	const alias = positions(helper, 'local renderer = ManifestMenu', true);
	if (alias.length !== 1) return null;
	return {
		platform,
		templateOffset: consumer.base + consumer.tokens[templates[0] + 3].start,
		manifestAliasOffset: helper.base + helper.tokens[alias[0] + 3].start
	};
}
function retainedPersonalInfoProjection(source) {
	return personalInfoEvidence(source) !== null;
}
function retainedPersonalInfoTemplateCallOffset(source, platform) {
	const evidence = personalInfoEvidence(source);
	return platform === undefined || evidence?.platform === platform
		? (evidence?.templateOffset ?? -1)
		: -1;
}
function retainedPersonalInfoManifestAliasOffset(source) {
	const evidence = personalInfoEvidence(source);
	return evidence?.platform === 'linux' ? evidence.manifestAliasOffset : -1;
}
module.exports = {
	retainedPersonalInfoProjection,
	retainedPersonalInfoTemplateCallOffset,
	retainedPersonalInfoManifestAliasOffset
};
