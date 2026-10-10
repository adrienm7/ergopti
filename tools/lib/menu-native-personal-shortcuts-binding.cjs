// tools/lib/menu-native-personal-shortcuts-binding.cjs

/** Necessary source evidence for the opted-in personal shortcut DATA route. */
'use strict';

const fs = require('fs');
const path = require('path');
const { scriptTokens } = require('./script-source.cjs');
const same = (a, b) =>
	a?.kind === b?.kind &&
	(a.kind === 'identifier' ? a.value.toLowerCase() === b.value.toLowerCase() : a.value === b.value);

/** Uses the existing native masking boundary, without extending its grammar. */
function executable(source) {
	const raw = fs.readFileSync(path.join(__dirname, '../test/test-ahk-loop-capture.cjs'), 'utf8');
	const start = raw.indexOf('function codeLines(src) {'),
		end = raw.indexOf('/**', start);
	if (start < 0 || end <= start) throw Error('Native masking owner unavailable');
	const lines = require('node:vm').runInNewContext(raw.slice(start, end) + '\ncodeLines')(source);
	const starts = [0];
	for (let at = 0; at < source.length; at++) if (source[at] === '\n') starts.push(at + 1);
	let line = 0;
	return scriptTokens(source, '.ahk').filter((token) => {
		while (line + 1 < starts.length && starts[line + 1] <= token.start) line++;
		if (token.kind === 'string')
			return source.slice(token.start, token.end) === JSON.stringify(token.value);
		const column = token.start - starts[line];
		return lines[line]?.slice(column, column + token.value.length) === token.value;
	});
}

function lexical(source) {
	const tokens = executable(source),
		levels = [],
		stack = [],
		pairs = new Map();
	const closes = { '(': ')', '[': ']', '{': '}' };
	for (let at = 0; at < tokens.length; at++) {
		levels.push(stack.filter((i) => tokens[i].value === '{').length);
		const token = tokens[at];
		if (token.kind !== 'symbol') continue;
		if (closes[token.value]) stack.push(at);
		else if ([')', ']', '}'].includes(token.value)) {
			const open = stack.pop();
			if (open === undefined || closes[tokens[open].value] !== token.value)
				throw Error('Incomplete native source');
			pairs.set(open, at);
		}
	}
	if (stack.length) throw Error('Incomplete native source');
	const id = (at, value) =>
		tokens[at]?.kind === 'identifier' &&
		(value === undefined || tokens[at].value.toLowerCase() === value.toLowerCase());
	const sym = (at, value) => tokens[at]?.kind === 'symbol' && tokens[at].value === value;
	// The tokenizer keeps each ampersand separate; only a contiguous pair is Boolean AND.
	const byReference = (at) => {
		if (!sym(at - 1, '&')) return false;
		const right = tokens[at - 1],
			left = tokens[at - 2],
			before = tokens[at - 3];
		return !(
			sym(at - 2, '&') &&
			left.end === right.start &&
			!(sym(at - 3, '&') && before.end === left.start)
		);
	};
	const line = (at) =>
		source.slice(source.lastIndexOf('\n', tokens[at].start - 1) + 1, tokens[at].start).trim() ===
		'';
	const fragments = new Map();
	const match = (at, fragment) => {
		if (!fragments.has(fragment)) fragments.set(fragment, scriptTokens(fragment, '.ahk'));
		return fragments.get(fragment).every((t, offset) => same(tokens[at + offset], t));
	};
	const hits = (fragment, body, depth) => {
		const found = [];
		for (let at = body.first; at < body.end; at++)
			if ((depth === undefined || levels[at] === depth) && line(at) && match(at, fragment))
				found.push(at);
		return found;
	};
	const unique = (fragment, body, depth) => {
		const found = hits(fragment, body, depth);
		if (found.length !== 1) throw Error('One actual native statement required');
		return found[0];
	};
	const owner = (name) => {
		const found = [];
		for (let at = 0; at < tokens.length; at++) {
			if (!id(at, name) || !sym(at + 1, '(') || levels[at] !== 0 || !line(at)) continue;
			const parameters = pairs.get(at + 1);
			if (!sym(parameters + 1, '{')) continue;
			found.push({
				index: at,
				parameters: tokens.slice(at + 2, parameters),
				first: parameters + 2,
				end: pairs.get(parameters + 1),
				depth: 1
			});
		}
		if (found.length !== 1) throw Error('One actual top-level personal registry owner');
		return found[0];
	};
	return { source, tokens, levels, pairs, id, sym, byReference, line, match, hits, unique, owner };
}

function reader(tokens) {
	let at = 0;
	return {
		at: () => at,
		peek: () => tokens[at],
		done: () => at === tokens.length,
		take: (fragment) => {
			const wanted = scriptTokens(fragment, '.ahk');
			if (!wanted.every((token, offset) => same(tokens[at + offset], token)))
				throw Error('Unsupported personal DATA grammar');
			at += wanted.length;
		},
		name: () => {
			if (tokens[at]?.kind !== 'identifier') throw Error('Actual local DATA binding required');
			return tokens[at++].value;
		},
		refusal: () => {
			if (tokens[at]?.kind !== 'string' || !tokens[at].value)
				throw Error('Actual refusal diagnostic required');
			at++;
		},
		string: () => {
			if (tokens[at]?.kind !== 'string') throw Error('Actual declaration literal required');
			return tokens[at++].value;
		}
	};
}

/** Reads roles from the real registry collector, rather than a candidate image. */
function personalProvider(unit) {
	const body = unit.owner('_PersonalShortcutRows');
	if (body.parameters.length) throw Error('DATA producer cannot receive a destination');
	const r = reader(unit.tokens.slice(body.first, body.end));
	r.take(
		'global _PersonalShortcutsRegistry if !_PersonalShortcutsRegistry.Has("__Order") { return 0 }'
	);
	const names = r.name();
	r.take(':= _PersonalShortcutsRegistry["__Order"] if (' + names + '.Length == 0) { return 0 }');
	const rows = r.name();
	r.take(':= [] for _,');
	const name = r.name();
	r.take('in ' + names + ' {');
	const description = r.name();
	r.take(
		':= _PersonalShortcutsRegistry.Has(' +
			name +
			') ? _PersonalShortcutsRegistry[' +
			name +
			'] : ""'
	);
	const label = r.name();
	r.take(':= (' + description + ' != "") ? ' + description + ' : ' + name);
	const row = r.name();
	r.take(':= MenuRowWithLabel("shortcuts.personal." . ' + name + ', ' + label + ', "Shortcuts")');
	r.take('if (' + row + ' != "") { ' + rows + '.Push(' + row + ') } } return ' + rows);
	if (
		!r.done() ||
		new Set([names, rows, name, description, label, row].map((v) => v.toLowerCase())).size !== 6
	)
		throw Error('Actual pure personal DATA return required');
	actualLocalRoles([names, rows, name, description, label, row]);
	return body;
}

function actualLocalRoles(names) {
	const reserved =
		/^(?:a_|global$|local$|static$|unset$|map$|array$|menu$|error$|menurenderer_|_personalshortcutrows$|_personalshortcutsregistry$|menurowwithlabel$)/i;
	if (names.some((name) => reserved.test(name)))
		throw Error('A local cannot replace a native owner');
}

function personalRegistration(unit) {
	const body = unit.owner('_BuildShortcutsSubmenu');
	if (body.parameters.length) throw Error('Actual shortcut builder signature required');
	const r = reader(unit.tokens.slice(body.first, body.end));
	const dynamic = r.name();
	r.take(':= Map()');
	const registration = r.name();
	r.take(':= Map("personal_shortcuts", Map(');
	const fields = new Map();
	for (let index = 0; index < 3; index++) {
		const key = r.string();
		r.take(',');
		if (fields.has(key)) throw Error('Duplicate frame registration');
		fields.set(
			key,
			key === 'provider'
				? { kind: 'identifier', value: r.name() }
				: { kind: 'string', value: r.string() }
		);
		if (index < 2) r.take(',');
	}
	r.take('))');
	if (
		fields.get('manifest_key')?.value !== 'personal_shortcuts_frame' ||
		fields.get('children_id')?.value !== 'personal_shortcuts_registered' ||
		fields.get('provider')?.value.toLowerCase() !== '_personalshortcutrows'
	)
		throw Error('Actual declared frame DATA binding required');
	const lists = r.name();
	r.take(':= Map("keyboard_slots", () => KeyboardSlotRows(), "tap_keys", () => TapKeyRows(),');
	r.take(
		'"wrap_symbols_menu", () => _SC_WrapSymbolRows(), "extensions_shortcuts", () => _SC_ExtensionRows(), )'
	);
	const commands = r.name();
	r.take(':= _SC_ScopeCommands()');
	const getters = r.name();
	r.take(':= _SC_Getters()');
	const groups = r.name();
	r.take(
		':= Map("key_combinations", () => _SC_KeyCombinationsSubmenu(), "script_control", () => _SC_ScriptControlSubmenu())'
	);
	r.take(
		'return MenuRenderer_Build("shortcuts_menu", "Shortcuts", ' +
			dynamic +
			', ' +
			groups +
			', ' +
			lists +
			', ' +
			commands +
			', ' +
			getters +
			', , , ' +
			registration +
			')'
	);
	if (
		!r.done() ||
		new Set([dynamic, registration, lists, commands, getters, groups].map((v) => v.toLowerCase()))
			.size !== 6
	)
		throw Error('Actual opted-in Build consumer required');
	actualLocalRoles([dynamic, registration, lists, commands, getters, groups]);
	return body;
}

/** The guard's owner pairs must name exactly the real captured native operations. */
function personalOwnerGuard(unit, receiver) {
	const obligations = new Map(
		Object.entries({
			EntryOwner: 'MenuRenderer_AppendFrameData',
			RootOwner: '_MR_GetManifestRoot',
			SharedRootOwner: '_MM_GetManifestRoot',
			DefinitionOwner: '_MR_GetMenuDef',
			SnapshotOwner: '_MR_ReasonedGroupSnapshot',
			CurrentOwner: '_MR_ReasonedGroupCurrent',
			TemplateOwner: 'MenuRenderer_TemplateRows',
			InnerTemplateOwner: '_MR_TemplateRows',
			AdmissionOwner: '_MR_AppendTemplateRowsAdmitted',
			LeafOwner: '_MR_FrameLeafAdmitted',
			RenderOwner: '_MR_RenderRows',
			NormalizeOwner: '_MR_NormalizeSeparators',
			RegisterOwner: 'RegisterMenuItem',
			PruneOwner: 'MenuDispatcher_PruneMenu',
			DestinationOwner: '_MR_FrameDestinationSnapshot',
			ReleaseOwner: '_MR_FrameReleaseChild',
			FrameOwner: '_MR_FrameDefinitionAdmitted',
			PlatformOwner: '_MR_IsForAhk',
			FieldOwner: '_MR_Get',
			TranslationOwner: 't',
			NativeConstructor: 'Menu',
			DllOwner: 'DllCall',
			CaptionOwner: 'TrayMenuItemCaption',
			CountOwner: 'TrayMenuItemCount',
			LookupOwner: '_MR_FindItemById',
			AliasOwner: 'MenuFromHandle',
			ImageOwner: '_MR_FrameNativeImageEqual',
			PendingOwner: '_MR_FramePendingOwnEntry',
			HandleCountOwner: 'TrayMenuHandleItemCount',
			PrefixOwner: '_MR_CommandLiteralPrefix',
			CaptionLayoutOwner: '_MR_CaptionLayoutMetadata',
			CaptionVectorOwner: '_MR_CaptionVectorMetadata',
			CountPolicyOwner: '_MR_TranslatedCountPolicy',
			CaptionFormatOwner: '_MR_CaptionFormat',
			DialectOwner: '_MR_ReportDriverDialect',
			PendingCaptureOwner: '_MR_FramePendingSnapshot',
			PendingCurrentOwner: '_MR_FramePendingCurrent',
			ReceiptCallbacksOwner: '_MR_FrameReceiptCallablesCurrent',
			ReceiptAdmissionOwner: '_MR_FrameReceiptAdmitted',
			PublishOwner: '_MR_FramePublish',
			StageOwner: '_MR_FrameStageAdmitted'
		})
	);
	for (const [alias, callable] of obligations) {
		let captures = 0,
			writes = 0;
		for (let at = receiver.first; at < receiver.end; at++) {
			if (!unit.id(at, alias)) continue;
			if (unit.sym(at + 1, ':=')) {
				writes++;
				if (
					unit.levels[at] === 1 &&
					unit.id(at + 2, callable) &&
					(unit.id(at - 1, 'static') || unit.sym(at - 1, ','))
				)
					captures++;
			}
			if (unit.byReference(at) || unit.sym(at - 1, '.'))
				throw Error('A retained callable cannot become a writable alias');
			if (unit.sym(at + 1, '.') && unit.sym(at + 3, ':='))
				throw Error('A retained callable cannot acquire an own method');
		}
		if (captures !== 1 || writes !== 1)
			throw Error('One genuine retained callable capture required');
	}
	const ownerAt = unit.unique('OwnersLive() {', receiver, 1),
		open = ownerAt + 3;
	const r = reader(unit.tokens.slice(open + 1, unit.pairs.get(open)));
	r.take('Pairs := [');
	const seen = new Set();
	while (true) {
		r.take('[');
		const alias = r.name();
		r.take(',');
		const callable = r.name();
		r.take(']');
		if (
			!obligations.has(alias) ||
			obligations.get(alias).toLowerCase() !== callable.toLowerCase() ||
			seen.has(alias)
		)
			throw Error('The current-source guard must retain each actual callable relationship');
		seen.add(alias);
		if (r.peek()?.kind !== 'symbol' || r.peek().value !== ',') break;
		r.take(',');
	}
	r.take(']');
	if (seen.size !== obligations.size)
		throw Error('All actual current-source callable owners required');
	r.take(
		'for Pair in Pairs if Pair[1] != Pair[2] || Object.Prototype.HasOwnProp.Call(Pair[1], "Call") return false'
	);
	r.take(
		'CurrentRegistries := [_MenuDispatchCallbacks, _MenuDispatchTokens, _MenuDispatchOwnerHandles, _MenuDispatchLastFire, _MenuDispatchClickSequences]'
	);
	r.take(
		'if _MenuDispatcherEpoch != DispatcherEpoch return false for Index, Registry in CurrentRegistries {'
	);
	r.take(
		'if Registry != RegistryOwners[Index] || !(Registry is Map) || ObjGetBase(Registry) != Map.Prototype return false for Name in ObjOwnProps(Registry) return false }'
	);
	r.take(
		'if !Object.Prototype.HasOwnProp.Call(Menu.Prototype, "Handle") || Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Handle").Get != NativeHandleGetter || Object.Prototype.HasOwnProp.Call(NativeHandleGetter, "Call") return false'
	);
	r.take('if !(TargetMenu is Menu) || ObjGetBase(TargetMenu) != Menu.Prototype return false');
	r.take(
		'for Name in ["Handle", "Add", "Delete", "Check", "Disable", "Enable", "Uncheck", "SetIcon"] if Object.Prototype.HasOwnProp.Call(TargetMenu, Name) return false'
	);
	r.take(
		'for Name, Method in NativeMethods { if !Object.Prototype.HasOwnProp.Call(Menu.Prototype, Name) || Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, Name).Call != Method || Object.Prototype.HasOwnProp.Call(Method, "Call") return false } return true'
	);
	if (!r.done()) throw Error('Actual native callable guard grammar required');
	unit.unique(
		'static NativeHandleGetter := Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Handle").Get',
		receiver,
		1
	);
	unit.unique('static NativeMethods := Map()', receiver, 1);
	unit.unique(
		'if NativeMethods.Count == 0 { for Name in ["Add", "Delete", "Check", "Disable", "Enable", "Uncheck", "SetIcon"] NativeMethods[Name] := Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, Name).Call }',
		receiver,
		1
	);
	unit.unique(
		'RegistryOwners := [_MenuDispatchCallbacks, _MenuDispatchTokens, _MenuDispatchOwnerHandles, _MenuDispatchLastFire, _MenuDispatchClickSequences] DispatcherEpoch := _MenuDispatcherEpoch',
		receiver,
		1
	);
	// Only genuine declaration/initialization grammar precedes the held owner guard.
	const prefix = reader(unit.tokens.slice(receiver.first, ownerAt));
	prefix.take(
		'global _MenuPopulationBuilding, _MenuDispatchCallbacks, _MenuDispatchTokens global _MenuDispatchOwnerHandles, _MenuDispatchLastFire, _MenuDispatchClickSequences, _MenuDispatcherEpoch'
	);
	const captured = new Set();
	while (prefix.peek()?.kind === 'identifier' && prefix.peek().value.toLowerCase() === 'static') {
		prefix.take('static');
		while (true) {
			const alias = prefix.name();
			prefix.take(':=');
			if (captured.has(alias)) throw Error('One actual entry capture required');
			captured.add(alias);
			if (obligations.has(alias)) prefix.take(obligations.get(alias));
			else if (alias === 'NativeHandleGetter')
				prefix.take('Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Handle").Get');
			else if (alias === 'NativeMethods') prefix.take('Map()');
			else throw Error('Unsupported entry callable capture');
			if (prefix.peek()?.kind !== 'symbol' || prefix.peek().value !== ',') break;
			prefix.take(',');
		}
	}
	if (captured.size !== obligations.size + 2)
		throw Error('Every actual entry owner must be captured');
	prefix.take(
		'if NativeMethods.Count == 0 { for Name in ["Add", "Delete", "Check", "Disable", "Enable", "Uncheck", "SetIcon"] NativeMethods[Name] := Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, Name).Call }'
	);
	prefix.take(
		'Admitted := false Child := false, ChildHandle := 0, LeafCallbacks := [], Published := false, Population := false, Pending := false, PendingEntry := false PrimaryError := false'
	);
	prefix.take(
		'RegistryOwners := [_MenuDispatchCallbacks, _MenuDispatchTokens, _MenuDispatchOwnerHandles, _MenuDispatchLastFire, _MenuDispatchClickSequences] DispatcherEpoch := _MenuDispatcherEpoch OriginalCritical := Critical("On")'
	);
	if (!prefix.done()) throw Error('Unsupported receiver entry authority statement');
	return unit.pairs.get(open) + 1;
}

/** Checks the personal registration's retained central receiver and live DATA edges. */
function personalCentral(unit) {
	const build = unit.owner('MenuRenderer_Build'),
		receiver = unit.owner('MenuRenderer_AppendFrameData');
	const entryEnd = personalOwnerGuard(unit, receiver);
	const signature = reader(build.parameters);
	signature.take(
		'ManifestKey, CategoryName, DynamicHandlers, GroupBuilders := "", ListProviders := "", Commands := "", StateGetters := "", TargetMenu := unset, GroupDisabled := unset, DeclaredFrames := unset'
	);
	if (!signature.done()) throw Error('Actual optional Build frame parameter required');
	const receiverSignature = reader(receiver.parameters);
	receiverSignature.take(
		'TargetMenu, ManifestKey, EntryId, Binding, ExpectedDefinition := unset, ExpectedItem := unset, &Admitted := unset, Registrations := unset'
	);
	if (!receiverSignature.done())
		throw Error('Actual retained destination receiver signature required');
	unit.unique(
		'static FrameDataOwner := MenuRenderer_AppendFrameData, FrameSnapshotOwner := _MR_ReasonedGroupSnapshot',
		build,
		1
	);
	const branchAt = unit.unique(
		'if IsSet(DeclaredFrames) && DeclaredFrames.Has(_MR_Get(Item, "id")) {',
		build,
		2
	);
	const open =
		branchAt +
		scriptTokens('if IsSet(DeclaredFrames) && DeclaredFrames.Has(_MR_Get(Item, "id"))', '.ahk')
			.length;
	const branch = { first: open + 1, end: unit.pairs.get(open) };
	const branchTokens = unit.tokens.slice(branch.first, branch.end);
	const callAt = unit.unique(
		'Added := FrameDataOwner.Call(Result, ManifestKey, Id, DeclaredFrames[Id], MenuDef, Item, &FrameAdmitted, [FrameBindings, HandlersReceipt, ProvidersReceipt])',
		branch,
		3
	);
	const pending = unit.unique('if PendingSep and ItemCount > 0 {', build, 2);
	const dispatch = reader(branchTokens);
	dispatch.take(
		'Id := _MR_Get(Item, "id") if ItemType != "list" || FrameDataOwner != MenuRenderer_AppendFrameData'
	);
	dispatch.take(
		'|| Object.Prototype.HasOwnProp.Call(FrameDataOwner, "Call") || !_MR_ReasonedGroupCurrent(FrameBindings)'
	);
	dispatch.take(
		'|| !_MR_ReasonedGroupCurrent(HandlersReceipt) || !_MR_ReasonedGroupCurrent(ProvidersReceipt)'
	);
	dispatch.take(
		'|| (DynamicHandlers is Map && DynamicHandlers.Has(Id)) || ListProviders.Has(Id) throw Error('
	);
	dispatch.refusal();
	dispatch.take(')');
	dispatch.take(
		'Added := FrameDataOwner.Call(Result, ManifestKey, Id, DeclaredFrames[Id], MenuDef, Item, &FrameAdmitted, [FrameBindings, HandlersReceipt, ProvidersReceipt])'
	);
	dispatch.take('if !FrameAdmitted throw Error(');
	dispatch.refusal();
	dispatch.take(') if Added > 0 PendingSep := false ItemCount += Added continue');
	if (!dispatch.done() || !(callAt < branch.end && branch.end < pending))
		throw Error('Refusal precedes actual publication');
	const snapshots = unit.unique('if IsSet(DeclaredFrames) {', build, 1);
	const snapshotOpen = snapshots + scriptTokens('if IsSet(DeclaredFrames)', '.ahk').length;
	const registration = reader(unit.tokens.slice(snapshotOpen + 1, unit.pairs.get(snapshotOpen)));
	registration.take(
		'if FrameDataOwner != MenuRenderer_AppendFrameData || FrameSnapshotOwner != _MR_ReasonedGroupSnapshot'
	);
	registration.take(
		'|| Object.Prototype.HasOwnProp.Call(FrameDataOwner, "Call") || Object.Prototype.HasOwnProp.Call(FrameSnapshotOwner, "Call") throw Error('
	);
	registration.refusal();
	registration.take(
		') FrameBindings := FrameSnapshotOwner.Call(DeclaredFrames) HandlersReceipt := FrameSnapshotOwner.Call(DynamicHandlers) ProvidersReceipt := FrameSnapshotOwner.Call(ListProviders)'
	);
	registration.take(
		'if !FrameBindings || !(DeclaredFrames is Map) || !HandlersReceipt || !ProvidersReceipt throw Error('
	);
	registration.refusal();
	registration.take(
		') for FrameId, Binding in DeclaredFrames { if Type(FrameId) != "String" || FrameId == "" || !(Binding is Map)'
	);
	registration.take(
		'|| (DynamicHandlers is Map && DynamicHandlers.Has(FrameId)) || ListProviders.Has(FrameId) throw Error('
	);
	registration.refusal();
	registration.take(') }');
	if (!registration.done()) throw Error('Actual authentic Build receipts required');
	const entry = reader(unit.tokens.slice(build.first, snapshots));
	entry.take(
		'if IsSet(TargetMenu) && (!(TargetMenu is Menu) || TrayMenuItemCount(TargetMenu) != 0) throw Error('
	);
	entry.refusal();
	entry.take(')');
	for (const role of ['GroupBuilders', 'ListProviders', 'Commands', 'StateGetters'])
		entry.take('if (' + role + ' == "") { ' + role + ' := Map() }');
	entry.take('if IsSet(GroupDisabled) { if !(GroupDisabled is Map) throw Error(');
	entry.refusal();
	entry.take(')');
	entry.take(
		'for Id, Disabled in GroupDisabled { if Type(Id) != "String" || Id == "" || Type(Disabled) != "Integer" || (Disabled != 0 && Disabled != 1) throw Error('
	);
	entry.refusal();
	entry.take(') } }');
	entry.take(
		'static FrameDataOwner := MenuRenderer_AppendFrameData, FrameSnapshotOwner := _MR_ReasonedGroupSnapshot'
	);
	if (!entry.done()) throw Error('Actual Build entry cannot conceal a dead frame witness');
	const registrationEnd = unit.pairs.get(snapshotOpen) + 1;
	const iteration = reader(unit.tokens.slice(registrationEnd, branchAt));
	iteration.take(
		'MenuDef := _MR_GetMenuDef(ManifestKey) if IsSet(TargetMenu) Result := TargetMenu else Result := Menu() ItemCount := 0 PendingSep := false for Item in MenuDef {'
	);
	iteration.take('if !_MR_CommandLiteralPrefix(Item, &Prefix) { try LoggerError("MenuRenderer",');
	iteration.refusal();
	iteration.take(') continue }');
	iteration.take(
		'if !_MR_IsForAhk(Item) { FilteredId := _MR_Get(Item, "id") if (FilteredId != "" and DynamicHandlers is Map and DynamicHandlers.Has(FilteredId)) { try LoggerDebug("MenuRenderer",'
	);
	iteration.refusal();
	iteration.take(', FilteredId, ManifestKey) }');
	iteration.take(
		'if _MR_Get(Item, "unavailable") == "grey" { if PendingSep and ItemCount > 0 Result.Add() PendingSep := false ItemCount += Item.Has("label_prefix") ? _MR_RenderGreyedStandIn(Result, Item, ManifestKey, Prefix . t(_MR_Get(Item, "i18n"))) : _MR_RenderGreyedStandIn(Result, Item, ManifestKey) } continue }'
	);
	iteration.take(
		'if Item.Has("caption_count_policy") && !_MR_TranslatedCountPolicy(Item) continue ItemType := _MR_Get(Item, "type", "") if ItemType == "---" { PendingSep := true continue }'
	);
	if (!iteration.done())
		throw Error('Actual selected frame branch must retain its live loop entry');
	const returns = unit.tokens
		.slice(build.first, build.end)
		.filter((t) => t.kind === 'identifier' && t.value.toLowerCase() === 'return');
	if (returns.length !== 1 || !unit.match(build.end - 2, 'return Result'))
		throw Error('Only actual completed Build result can return');
	const primaryTry = unit.unique('try {', receiver, 1),
		primaryOpen = primaryTry + 1;
	if (entryEnd !== primaryTry) throw Error('No dead receiving witness before actual main try');
	const main = { first: primaryOpen + 1, end: unit.pairs.get(primaryOpen) };
	unit.unique(
		'static TemplateOwner := MenuRenderer_TemplateRows, InnerTemplateOwner := _MR_TemplateRows',
		receiver,
		1
	);
	unit.unique('static NativeConstructor := Menu, DllOwner := DllCall', receiver, 1);
	unit.unique(
		'FrameKey := Binding["manifest_key"], ChildId := Binding["children_id"], Provider := Binding["provider"]',
		main,
		2
	);
	unit.unique(
		'if Type(FrameKey) != "String" || FrameKey == "" || Type(ChildId) != "String" || ChildId == "" || !(Provider is Func) || Object.Prototype.HasOwnProp.Call(Provider, "Call") return 0',
		main,
		2
	);
	unit.unique('if !DestinationLive() return 0 Data := Provider.Call()', main, 2);
	unit.unique(
		'if IsSet(Registrations) { RegistrationsReceipt := SnapshotOwner.Call(Registrations) if !OwnersLive() || !RegistrationsReceipt || !(Registrations is Array) || Registrations.Length != 3 return 0 for Receipt in Registrations if !ReceiptAdmissionOwner.Call(Receipt) return 0 }',
		main,
		2
	);
	const sourceAt = unit.unique('SourceLive() {', main, 2),
		sourceOpen = sourceAt + 3;
	const live = { first: sourceOpen + 1, end: unit.pairs.get(sourceOpen) };
	const admitted = reader(unit.tokens.slice(main.first, sourceAt));
	admitted.take(
		'if !OwnersLive() || Type(ManifestKey) != "String" || ManifestKey == "" || Type(EntryId) != "String" || EntryId == "" return 0 BindingReceipt := SnapshotOwner.Call(Binding)'
	);
	admitted.take(
		'if !OwnersLive() || !BindingReceipt || !(Binding is Map) || Binding.Count != 3 || !Binding.Has("manifest_key") || !Binding.Has("children_id") || !Binding.Has("provider") return 0'
	);
	admitted.take(
		'if IsSet(Registrations) { RegistrationsReceipt := SnapshotOwner.Call(Registrations) if !OwnersLive() || !RegistrationsReceipt || !(Registrations is Array) || Registrations.Length != 3 return 0 for Receipt in Registrations if !ReceiptAdmissionOwner.Call(Receipt) return 0 }'
	);
	admitted.take(
		'FrameKey := Binding["manifest_key"], ChildId := Binding["children_id"], Provider := Binding["provider"] if Type(FrameKey) != "String" || FrameKey == "" || Type(ChildId) != "String" || ChildId == "" || !(Provider is Func) || Object.Prototype.HasOwnProp.Call(Provider, "Call") return 0'
	);
	admitted.take(
		'Root := RootOwner.Call() if !OwnersLive() || !(Root is Map) || ObjGetBase(Root) != Map.Prototype return 0 for Name in ObjOwnProps(Root) return 0'
	);
	admitted.take(
		'Definition := DefinitionOwner.Call(ManifestKey), Frame := DefinitionOwner.Call(FrameKey) if !OwnersLive() || !(Root is Map) || !Root.Has(ManifestKey) || !Root.Has(FrameKey) || Root[ManifestKey] != Definition || Root[FrameKey] != Frame || (IsSet(ExpectedDefinition) && Definition != ExpectedDefinition) return 0'
	);
	admitted.take(
		'DefinitionReceipt := SnapshotOwner.Call(Definition), FrameReceipt := SnapshotOwner.Call(Frame) if !OwnersLive() || !DefinitionReceipt || !FrameReceipt return 0 Selected := false, Matches := 0'
	);
	admitted.take(
		'for Item in Definition { if Item is Map && Item.Get("id", "") == EntryId { Selected := Item, Matches += 1 } }'
	);
	admitted.take(
		'if Matches != 1 || Selected.Get("type", "") != "list" || !PlatformOwner.Call(Selected) || (IsSet(ExpectedItem) && Selected != ExpectedItem) || !FrameOwner.Call(Frame, ChildId) || !OwnersLive() return 0'
	);
	admitted.take(
		'Handle := TargetMenu.Handle, Destination := DestinationOwner.Call(TargetMenu) if !OwnersLive() || !Destination return 0 Population := _MenuPopulationBuilding'
	);
	admitted.take(
		'if Population is MenuPopulation { if ObjGetBase(Population) != MenuPopulation.Prototype || Object.Prototype.HasOwnProp.Call(Population, "Fill") || !Object.Prototype.HasOwnProp.Call(Population, "Pending") return 0'
	);
	admitted.take(
		'PendingDesc := Object.Prototype.GetOwnPropDesc.Call(Population, "Pending") if !PendingDesc.HasOwnProp("Value") return 0 Pending := PendingDesc.Value PendingReceipt := PendingCaptureOwner.Call(Pending) if !PendingReceipt || !(Pending is Map) return 0'
	);
	admitted.take(
		'FillOwner := Object.Prototype.GetOwnPropDesc.Call(MenuPopulation.Prototype, "Fill").Call if Object.Prototype.HasOwnProp.Call(FillOwner, "Call") return 0 } else if Type(Population) != "Integer" || Population != 0 return 0'
	);
	if (!admitted.done())
		throw Error('Actual receiver source admission cannot conceal a dead DATA witness');
	const held = reader(unit.tokens.slice(live.first, live.end));
	held.take(
		'if Type(Child) != "Integer" || Child != 0 { if !(Child is Menu) || ObjGetBase(Child) != Menu.Prototype return false for Name in ["Handle", "Add", "Delete", "Check", "Disable", "Enable", "Uncheck", "SetIcon"] if Object.Prototype.HasOwnProp.Call(Child, Name) return false }'
	);
	held.take(
		'if !OwnersLive() || Object.Prototype.HasOwnProp.Call(Provider, "Call") || !CurrentOwner.Call(BindingReceipt) return false'
	);
	held.take(
		'if IsSet(Registrations) { if !CurrentOwner.Call(RegistrationsReceipt) return false for Receipt in Registrations if !CurrentOwner.Call(Receipt) || !ReceiptCallbacksOwner.Call(Receipt) return false'
	);
	held.take(
		'Frames := Registrations[1]["value"] Handlers := Registrations[2]["value"], Providers := Registrations[3]["value"]'
	);
	held.take(
		'if !(Frames is Map) || !Frames.Has(EntryId) || Frames[EntryId] != Binding || (Handlers is Map && Handlers.Has(EntryId)) || (Providers is Map && Providers.Has(EntryId)) return false }'
	);
	held.take(
		'CurrentRoot := RootOwner.Call() if !OwnersLive() || CurrentRoot != Root || ObjGetBase(Root) != Map.Prototype return false for Name in ObjOwnProps(Root) return false'
	);
	held.take(
		'if !Root.Has(ManifestKey) || !Root.Has(FrameKey) || Root[ManifestKey] != Definition || Root[FrameKey] != Frame || !CurrentOwner.Call(DefinitionReceipt) || !CurrentOwner.Call(FrameReceipt)'
	);
	held.take(
		'|| Selected.Get("type", "") != "list" || !PlatformOwner.Call(Selected) || !FrameOwner.Call(Frame, ChildId) || !OwnersLive() || TargetMenu.Handle != Handle || _MenuPopulationBuilding != Population return false'
	);
	held.take(
		'if Population is MenuPopulation { if Object.Prototype.HasOwnProp.Call(Population, "Fill") || Object.Prototype.GetOwnPropDesc.Call(MenuPopulation.Prototype, "Fill").Call != FillOwner || Object.Prototype.HasOwnProp.Call(FillOwner, "Call") return false'
	);
	held.take('NowPending := Object.Prototype.GetOwnPropDesc.Call(Population, "Pending")');
	held.take(
		'if !NowPending.HasOwnProp("Value") || NowPending.Value != Pending return false if !PendingCurrentOwner.Call(PendingReceipt, Child, PendingEntry) return false } return OwnersLive()'
	);
	if (!held.done()) throw Error('Actual live registration and source grammar required');
	const destinationAt = unit.unique('DestinationLive() {', main, 2),
		destinationOpen = destinationAt + 3;
	if (live.end + 1 !== destinationAt)
		throw Error('Actual live source guard cannot conceal a dead DATA witness');
	const destination = reader(
		unit.tokens.slice(destinationOpen + 1, unit.pairs.get(destinationOpen))
	);
	destination.take(
		'if !SourceLive() return false Now := DestinationOwner.Call(TargetMenu) return SourceLive() && (Now is Array) && ImageOwner.Call(Destination, Now)'
	);
	if (!destination.done()) throw Error('Actual current destination and source required');
	const projection = unit.unique(
		'Rows := TemplateOwner.Call(FrameKey, Map(), Map(), Map(ChildId, Data))',
		main,
		2
	);
	const allocation = unit.unique('Child := NativeConstructor.Call()', main, 2);
	const dataAt = unit.unique('Data := Provider.Call()', main, 2);
	const beforeData = reader(unit.tokens.slice(unit.pairs.get(destinationOpen) + 1, dataAt));
	beforeData.take('if !DestinationLive() return 0');
	if (!beforeData.done())
		throw Error('Actual provider invocation cannot conceal a dead DATA witness');
	const rowsAt = unit.unique('RowsReceipt := SnapshotOwner.Call(Rows)', main, 2);
	const stages = unit.tokens.slice(dataAt, allocation);
	const r = reader(stages);
	r.take(
		'Data := Provider.Call() if !DestinationLive() return 0 if Type(Data) == "Integer" && Data == 0 { Admitted := true return 0 }'
	);
	r.take(
		'if !LeafOwner.Call(Data) || !DestinationLive() return 0 DataReceipt := SnapshotOwner.Call(Data) if !DataReceipt || !DestinationLive() return 0'
	);
	// A genuinely unused scalar local cannot acquire or replace a route owner.
	const scalarAt = r.at(),
		scalar = stages[scalarAt];
	if (
		scalar?.kind === 'identifier' &&
		stages[scalarAt + 1]?.kind === 'symbol' &&
		stages[scalarAt + 1].value === ':=' &&
		stages[scalarAt + 2]?.kind === 'string' &&
		!/^a_/i.test(scalar.value) &&
		unit.tokens.filter(
			(t) => t.kind === 'identifier' && t.value.toLowerCase() === scalar.value.toLowerCase()
		).length === 1
	)
		r.take(scalar.value + ' := ' + JSON.stringify(stages[scalarAt + 2].value));
	r.take('Rows := TemplateOwner.Call(FrameKey, Map(), Map(), Map(ChildId, Data))');
	r.take(
		'if !DestinationLive() || !CurrentOwner.Call(DataReceipt) || !LeafOwner.Call(Data) || !AdmissionOwner.Call(Rows, 1, Map()) || Rows.Length != Frame.Length'
	);
	r.take(
		'|| !Rows[Rows.Length].Has("items") || Rows[Rows.Length]["items"] != Data return 0 RowsReceipt := SnapshotOwner.Call(Rows) if !RowsReceipt || !DestinationLive() return 0 for Leaf in Data LeafCallbacks.Push(Leaf["action"])'
	);
	if (!r.done() || !(dataAt < projection && projection < rowsAt && rowsAt < allocation))
		throw Error('Actual native child lexical kinds');
	const parent = unit.unique(
		'Parent := Rows[Rows.Length], Label := StrReplace(Parent["label"], "&", "&&")',
		main,
		2
	);
	const staged = reader(unit.tokens.slice(allocation, parent));
	staged.take(
		'Child := NativeConstructor.Call() ChildHandle := Child.Handle if !DestinationLive() return 0 if Population is MenuPopulation { FillOwner.Call(Population, Child, Data, FrameKey, 2) PendingEntry := PendingOwner.Call(Pending, Child, ChildHandle) } else { if RenderOwner.Call(Child, Data, FrameKey, 2, 0, true) != Data.Length return 0 NormalizeOwner.Call(Child) }'
	);
	staged.take(
		'if !DestinationLive() || !CurrentOwner.Call(DataReceipt) || !LeafOwner.Call(Data) || !CurrentOwner.Call(RowsReceipt) return 0 StageReceipt := DestinationOwner.Call(Child) if !DestinationLive() || !StageOwner.Call(StageReceipt, Data, Population is MenuPopulation) return 0'
	);
	if (!staged.done()) throw Error('Actual completed DATA stage required');
	unit.unique(
		'if CaptionMatches > 1 || !DestinationLive() || !CurrentOwner.Call(DataReceipt) || !LeafOwner.Call(Data) || !CurrentOwner.Call(RowsReceipt) return 0',
		main,
		2
	);
	const publicationAt = unit.unique('PublicationLive() {', main, 2),
		publicationOpen = publicationAt + 3;
	const parentStage = reader(unit.tokens.slice(parent, publicationAt));
	parentStage.take(
		'Parent := Rows[Rows.Length], Label := StrReplace(Parent["label"], "&", "&&") OldChild := false, OldParentFlags := 0, CaptionMatches := 0'
	);
	parentStage.take(
		'for NativeRow in Destination { if NativeRow[1] == Label { CaptionMatches += 1 if NativeRow[4] == 0 return 0 OldChild := AliasOwner.Call(NativeRow[4]), OldParentFlags := NativeRow[3] } }'
	);
	parentStage.take(
		'if CaptionMatches > 1 || !DestinationLive() || !CurrentOwner.Call(DataReceipt) || !LeafOwner.Call(Data) || !CurrentOwner.Call(RowsReceipt) return 0'
	);
	if (!parentStage.done())
		throw Error('Actual completed parent cannot conceal a dead native publication witness');
	const publication = reader(
		unit.tokens.slice(publicationOpen + 1, unit.pairs.get(publicationOpen))
	);
	publication.take(
		'if !SourceLive() || !CurrentOwner.Call(DataReceipt) || !LeafOwner.Call(Data) || !CurrentOwner.Call(RowsReceipt) return false NowStage := DestinationOwner.Call(Child)'
	);
	publication.take(
		'return SourceLive() && StageOwner.Call(NowStage, Data, Population is MenuPopulation) && ImageOwner.Call(StageReceipt, NowStage)'
	);
	if (!publication.done())
		throw Error('Actual native stage identity must remain current at publication');
	const final = reader(unit.tokens.slice(unit.pairs.get(publicationOpen) + 1, main.end));
	final.take(
		'if !PublicationLive() || !DestinationLive() return 0 Added := PublishOwner.Call(TargetMenu, Child, Rows, Label, Destination, NativeMethods, OldChild, OldParentFlags, PublicationLive) Published := true, Admitted := true return Added'
	);
	if (!final.done())
		throw Error('Actual retained completed DATA must reach the native publication operation');
	personalOperation(unit);
	return { body: receiver, projection, allocation };
}

/** The internal operation consumes the genuine child and current-source closure. */
function personalOperation(unit) {
	const stage = unit.owner('_MR_FrameStageAdmitted'),
		publish = unit.owner('_MR_FramePublish');
	const stageSignature = reader(stage.parameters);
	stageSignature.take('Stage, Data, Seeded');
	const publishSignature = reader(publish.parameters);
	publishSignature.take(
		'Target, Child, Rows, Label, Before, NativeMethods, OldChild, OldFlags, Current'
	);
	if (!stageSignature.done() || !publishSignature.done())
		throw Error('Actual internal native operation signatures required');
	const admit = reader(unit.tokens.slice(stage.first, stage.end));
	admit.take(
		'if !(Stage is Array) || !_MR_FrameLeafAdmitted(Data) return false Expected := [], Positions := Map() for Index, Row in Data { if Seeded && Index > 1 break Label := StrReplace(Row["label"], "&", "&&")'
	);
	admit.take(
		'if Positions.Has(Label) Expected[Positions[Label]][2] := Row["action"] else { Expected.Push([Label, Row["action"]]) Positions[Label] := Expected.Length } }'
	);
	admit.take(
		'if Stage.Length != Expected.Length return false for Index, Row in Stage if !(Row[1] == Expected[Index][1]) || Row[4] != 0 || Row[5] != Expected[Index][2] || Type(Row[6]) != "Integer" || Row[6] <= 0 return false return true'
	);
	if (!admit.done()) throw Error('Actual staged callback/label admission required');
	const tryAt = unit.unique('try {', publish, 1),
		open = tryAt + 1;
	const entry = reader(unit.tokens.slice(publish.first, tryAt));
	entry.take(
		'if !(Current is Func) || Object.Prototype.HasOwnProp.Call(Current, "Call") throw Error('
	);
	entry.refusal();
	entry.take(') StartCount := Before.Length');
	if (!entry.done()) throw Error('The native operation cannot conceal a dead publication witness');
	const operation = reader(unit.tokens.slice(open + 1, unit.pairs.get(open)));
	operation.take(
		'loop Rows.Length - 1 { if Object.Prototype.HasOwnProp.Call(Current, "Call") || !Current.Call() throw Error('
	);
	operation.refusal();
	operation.take(') NativeMethods["Add"].Call(Target)');
	operation.take(
		'if Object.Prototype.HasOwnProp.Call(Current, "Call") || !Current.Call() throw Error('
	);
	operation.refusal();
	operation.take(') }');
	operation.take(
		'if Object.Prototype.HasOwnProp.Call(Current, "Call") || !Current.Call() throw Error('
	);
	operation.refusal();
	operation.take(') NativeMethods["Add"].Call(Target, Label, Child)');
	operation.take(
		'if Object.Prototype.HasOwnProp.Call(Current, "Call") || !Current.Call() throw Error('
	);
	operation.refusal();
	operation.take(') return 1');
	if (!operation.done())
		throw Error(
			'Actual retained native child must reach native Add under its current-source closure'
		);
}

/** Refuses reflective or assigned callable authority; no generic alias transport. */
function personalAuthority(unit) {
	const receiver = unit.owner('MenuRenderer_AppendFrameData'),
		build = unit.owner('MenuRenderer_Build');
	const provider = unit.owner('_PersonalShortcutRows'),
		caller = unit.owner('_BuildShortcutsSubmenu');
	const template = unit.owner('MenuRenderer_TemplateRows'),
		operation = unit.owner('_MR_FramePublish'),
		stage = unit.owner('_MR_FrameStageAdmitted');
	for (let at = 0; at < unit.tokens.length; at++) {
		if (!unit.id(at, 'Menu') && !unit.id(at, 'Map')) continue;
		if (
			unit.sym(at + 1, ':=') ||
			(unit.sym(at + 1, '(') && unit.sym(unit.pairs.get(at + 1) + 1, '{')) ||
			(unit.sym(at + 1, '.') && unit.sym(at + 3, ':='))
		)
			throw Error('Native constructor identity cannot be rebound');
	}
	const protectedCalls = new Set([
		'_personalshortcutrows',
		'_buildshortcutssubmenu',
		'menurenderer_build',
		'menurenderer_appendframedata',
		'menurenderer_templaterows',
		'menurowwithlabel',
		'_mr_framepublish',
		'_mr_framestageadmitted'
	]);
	const retained = new Map([
		['menurenderer_appendframedata', ['FrameDataOwner', 'EntryOwner']],
		['menurenderer_templaterows', ['TemplateOwner']],
		['_mr_framepublish', ['PublishOwner']],
		['_mr_framestageadmitted', ['StageOwner']]
	]);
	for (let at = 0; at < unit.tokens.length; at++) {
		const token = unit.tokens[at];
		if (token.kind !== 'identifier' || !protectedCalls.has(token.value.toLowerCase())) continue;
		const name = token.value.toLowerCase();
		if (
			[
				receiver.index,
				build.index,
				provider.index,
				caller.index,
				template.index,
				operation.index,
				stage.index
			].includes(at)
		)
			continue;
		if (
			name === '_personalshortcutrows' &&
			unit.tokens[at - 2]?.kind === 'string' &&
			unit.tokens[at - 2].value === 'provider' &&
			unit.sym(at - 1, ',') &&
			at > caller.first &&
			at < caller.end
		)
			continue;
		const aliases = retained.get(name) || [];
		if (
			aliases.some(
				(alias) =>
					(unit.sym(at - 1, ':=') &&
						unit.id(at - 2, alias) &&
						(unit.id(at - 3, 'static') || unit.sym(at - 3, ','))) ||
					(unit.sym(at - 1, '=') && unit.sym(at - 2, '!') && unit.id(at - 3, alias)) ||
					(unit.sym(at - 1, ',') && unit.id(at - 2, alias) && unit.sym(at - 3, '['))
			)
		)
			continue;
		if (
			unit.sym(at + 1, '(') &&
			!['.', ':', '['].includes(unit.tokens[at - 1]?.value) &&
			!unit.sym(unit.pairs.get(at + 1) + 1, '{')
		)
			continue;
		throw Error('A canonical personal callable cannot become reflective or assigned authority');
	}
	// Held route identities have one genuine binding and cannot be overwritten later.
	for (const role of [
		'Provider',
		'FrameKey',
		'ChildId',
		'Data',
		'Rows',
		'RowsReceipt',
		'DataReceipt',
		'BindingReceipt',
		'RegistrationsReceipt',
		'NativeConstructor',
		'TemplateOwner',
		'SnapshotOwner',
		'CurrentOwner',
		'LeafOwner',
		'AdmissionOwner',
		'FrameOwner',
		'EntryOwner',
		'StageReceipt',
		'PublishOwner',
		'StageOwner'
	]) {
		let writes = 0;
		for (let at = receiver.first; at < receiver.end; at++) {
			if (!unit.id(at, role)) continue;
			if (unit.sym(at + 1, ':=')) writes++;
			// These index operands read the held frame and its own Array bound, not an alias.
			const ownIndexRead =
				(role === 'FrameKey' && unit.match(at - 2, 'Root[FrameKey] != Frame')) ||
				(role === 'Rows' && unit.match(at - 2, 'Rows[Rows.Length]'));
			if (
				unit.sym(at - 1, '.') ||
				(unit.sym(at - 1, '[') && !unit.sym(at + 1, ',') && !ownIndexRead) ||
				unit.byReference(at)
			)
				throw Error('A held personal DATA identity cannot be a member or writable alias');
			if (unit.sym(at + 1, '.') || unit.sym(at + 1, '[')) {
				let end = at + 2;
				if (unit.sym(at + 1, '[')) end = unit.pairs.get(at + 1) + 1;
				else end++;
				if (unit.sym(end, ':=')) throw Error('A held personal DATA identity cannot be mutated');
			}
		}
		if (writes !== 1) throw Error('One actual held personal DATA binding required');
	}
	for (const role of [
		'FrameDataOwner',
		'FrameSnapshotOwner',
		'FrameBindings',
		'HandlersReceipt',
		'ProvidersReceipt'
	]) {
		let writes = 0;
		for (let at = build.first; at < build.end; at++)
			if (unit.id(at, role) && unit.sym(at + 1, ':=')) writes++;
		if (writes !== 1) throw Error('One actual held Build registration binding required');
	}
	// Source guards are lexical owners, not replaceable lambda/member definitions.
	for (const role of ['SourceLive', 'DestinationLive', 'OwnersLive', 'PublicationLive']) {
		let owners = 0;
		for (let at = receiver.first; at < receiver.end; at++) {
			if (!unit.id(at, role)) continue;
			if (role === 'PublicationLive' && unit.sym(at - 1, ',') && unit.sym(at + 1, ')')) continue;
			if (!unit.sym(at + 1, '(') || ['.', ':', '['].includes(unit.tokens[at - 1]?.value))
				throw Error('Actual current source guard cannot become an alias');
			if (unit.sym(unit.pairs.get(at + 1) + 1, '{')) owners++;
		}
		if (owners !== 1) throw Error('One actual current source guard required');
	}
}

/** Dedicated opt-in proof; generic template publication never gains this mode. */
function personalFrameDataPublication(source, definition, owningEntry) {
	try {
		if (
			typeof source !== 'string' ||
			!require('node:util').isDeepStrictEqual(definition, [
				{ type: '---', platforms: ['ahk'], unavailable: 'hide' },
				{
					type: 'group',
					id: 'personal_shortcuts_registered',
					i18n: 'menu.shortcuts.personal',
					platforms: ['ahk'],
					unavailable: 'hide'
				}
			]) ||
			owningEntry?.type !== 'list' ||
			owningEntry.id !== 'personal_shortcuts' ||
			!require('node:util').isDeepStrictEqual(owningEntry.platforms, ['ahk'])
		)
			return false;
		const unit = lexical(source);
		personalProvider(unit);
		personalRegistration(unit);
		personalCentral(unit);
		personalAuthority(unit);
		return true;
	} catch {
		return false;
	}
}

module.exports = { personalFrameDataPublication };
