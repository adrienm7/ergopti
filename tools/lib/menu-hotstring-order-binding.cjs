// tools/lib/menu-hotstring-order-binding.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Order Shared Menu Evidence
 * DESCRIPTION:
 * Follows the native template function into the finite shared section-order
 * producer. A require alone, a decorative call or a withdrawn shared callback
 * supplies no menu/getter/handler evidence. This is source evidence, not a
 * replacement for the native movement and persistence regression suites.
 * ==============================================================================
 */

'use strict';

const { scriptTokens } = require('./script-source.cjs');
const { expandConfigKeys } = require('./config-key-tokens.cjs');

const MENU_METHOD = `function M.menu(template_rows, order, labels, commit, ready)
 if type(template_rows) ~= "function" then
  Logger.error("hotstrings.section_order", "Section-order templates are unavailable.")
  return {}
 end
 local function admitted()
  local called, value = pcall(ready)
  if not called then Logger.error("hotstrings.section_order", "Section-order admission could not be read.") end
  return called and value == true
 end
 local function render(...)
  local called, rows = pcall(template_rows, ...)
  if not called or type(rows) ~= "table" then
   Logger.error("hotstrings.section_order", "Section-order template rendering was refused.")
   return nil
  end
  return rows
 end
 local entries = {}
 for _, name in ipairs(order) do
  if name ~= "-" and labels[name] then
   local function move(delta)
    if not admitted() then return false end
    local next_order = M.move(order, name, delta, labels)
    return next_order ~= nil and commit(next_order) == true
   end
   local children = render("hotstring_order_moves", {
    [COMMAND.HOTSTRING_ORDER_UP] = function() return move(-1) end,
    [COMMAND.HOTSTRING_ORDER_DOWN] = function() return move(1) end,
   }, {
    hotstring_order_up_ready = function() return admitted() and M.move(order, name, -1, labels) ~= nil end,
    hotstring_order_down_ready = function() return admitted() and M.move(order, name, 1, labels) ~= nil end,
   }, {})
   if not children then return {} end
   entries[#entries + 1] = { label = labels[name], items = children }
  end
 end
 if #entries < 2 then return {} end
 local reset = render("hotstring_order_footer", {
  [COMMAND.HOTSTRING_ORDER_RESET] = function() return admitted() and commit(nil) == true end,
 }, { hotstring_order_ready = admitted }, {})
 if not reset then return {} end
 for _, row in ipairs(reset) do entries[#entries + 1] = row end
 return render("hotstring_order_parent", {}, {}, { hotstring_order_children = entries }) or {}
end
return M`;

const tokens = (source) => scriptTokens(source, '.lua');
const same = (actual, expected) =>
	actual?.kind === expected.kind && actual.value === expected.value;
const starts = (source, fragment) => {
	const expected = tokens(fragment);
	return source.flatMap((_, at) =>
		expected.every((item, offset) => same(source[at + offset], item)) ? [at] : []
	);
};

/** Return only the physically reached shared menu method, or no evidence. */
function hotstringOrderMenuSource(nativeSource, sharedSource) {
	const native = tokens(nativeSource);
	const binding = starts(native, 'local SectionOrder = require("hotstrings.section_order")');
	if (binding.length !== 1) return '';
	const direct = starts(native, 'local ManifestMenu = require("infra.manifest_menu")');
	const protectedBinding = starts(
		native,
		'local ok_mm, ManifestMenu = pcall(require, "infra.manifest_menu")'
	);
	if (direct.length + protectedBinding.length !== 1) return '';
	const lastImport = Math.max(binding[0], direct[0] ?? protectedBinding[0]);
	if (
		native
			.slice(0, lastImport)
			.some(
				(token) =>
					token.kind === 'identifier' &&
					['if', 'for', 'while', 'repeat', 'function'].includes(token.value)
			)
	)
		return '';
	const guard = starts(
		native,
		'if not ok_mm or type(ManifestMenu) ~= "table" then ManifestMenu = nil end'
	);
	const guardAssignment =
		guard[0] + tokens('if not ok_mm or type(ManifestMenu) ~= "table" then').length;
	if (protectedBinding.length && guard.length !== 1) return '';
	// The physical aliases may not be rebound or captured by a same-named parameter.
	for (let at = 0; at < native.length; at++) {
		const token = native[at];
		if (token.kind !== 'identifier') continue;
		if (
			token.value === 'SectionOrder' &&
			at !== binding[0] + 1 &&
			!(
				native[at + 1]?.value === '.' &&
				['resolve', 'menu'].includes(native[at + 2]?.value) &&
				native[at + 3]?.value === '(' &&
				native[at - 1]?.value !== 'function'
			)
		)
			return '';
		if (
			token.value === 'ManifestMenu' &&
			native[at + 1]?.value === '=' &&
			at !== direct[0] + 1 &&
			at !== protectedBinding[0] + 3 &&
			at !== guardAssignment
		)
			return '';
		if (
			token.value === 'ManifestMenu' &&
			(native[at + 1]?.value === '[' ||
				(native[at + 1]?.value === '.' && native[at + 3]?.value === '='))
		)
			return '';
		if (token.value === 'function') {
			let open = at + 1;
			while (open < native.length && native[open].value !== '(') open++;
			for (
				let parameter = open + 1;
				parameter < native.length && native[parameter].value !== ')';
				parameter++
			)
				if (['SectionOrder', 'ManifestMenu'].includes(native[parameter].value)) return '';
		}
	}
	let published = false;
	for (const at of starts(
		native,
		'local order_rows = SectionOrder.menu(ManifestMenu.template_rows,'
	)) {
		const open = at + 6;
		let depth = 1,
			end = open + 1;
		for (; end < native.length && depth; end++) {
			if (native[end].kind !== 'symbol') continue;
			if (native[end].value === '(') depth++;
			if (native[end].value === ')') depth--;
		}
		if (depth) return '';
		for (const list of ['sub', 'sec_menu']) {
			const handoff = tokens(`for _, row in ipairs(order_rows) do ${list}[#${list} + 1] = row end`);
			if (handoff.every((item, offset) => same(native[end + offset], item))) published = true;
		}
	}
	if (!published) return '';
	const expanded = expandConfigKeys(sharedSource);
	const shared = tokens(expanded),
		expected = tokens(MENU_METHOD);
	const commandBinding = 'local COMMAND = require("config_keys").COMMAND';
	const commandStarts = starts(shared, commandBinding);
	if (commandStarts.length !== 1) return '';
	const methods = starts(shared, 'function M.menu(');
	if (methods.length !== 1 || shared.length - methods[0] !== expected.length) return '';
	for (let at = 0; at < methods[0]; at++)
		if (
			shared[at].kind === 'identifier' &&
			shared[at].value === 'COMMAND' &&
			at !== commandStarts[0] + 1 &&
			at !== commandStarts[0] + tokens(commandBinding).length - 1
		)
			return '';
	if (!expected.every((item, offset) => same(shared[methods[0] + offset], item))) return '';
	const commandStart = shared[commandStarts[0]].start;
	const commandEnd = shared[commandStarts[0] + tokens(commandBinding).length - 1].end;
	return expanded.slice(commandStart, commandEnd) + '\n' + expanded.slice(shared[methods[0]].start);
}

module.exports = { hotstringOrderMenuSource };
