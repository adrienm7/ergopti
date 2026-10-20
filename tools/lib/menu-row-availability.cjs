// tools/lib/menu-row-availability.cjs

/**
 * Canonical availability declarations shared by the menu compiler and I2.
 * HIDE describes a presentation that does not apply on the omitted platforms;
 * GREY describes a presentation not yet ported, with its translated reason.
 * Only the caller's actual [menu.*] row receives this classification. Feature
 * and section restrictions continue to describe product capabilities.
 */
'use strict';

const PLATFORMS = ['ahk', 'hs', 'linux'];
// Source row types described by the compiler's generated-manifest header.
const ROW_TYPES = new Set([
	'toggle',
	'feature',
	'action',
	'dynamic',
	'group',
	'include',
	'label',
	'section_header',
	'---',
	'list',
	'letter_picker',
	'choice',
	'command',
	'check',
	'native_content'
]);

/** Counts ordered scalar slots with the native renderers' percent-token rules. */
function nativeCountSlots(format) {
	if (typeof format !== 'string') return -1;
	let slots = 0;
	for (let index = 0; index < format.length; index += 1) {
		if (format[index] !== '%') continue;
		const following = format[index + 1];
		if (following === 's') slots += 1;
		else if (following !== '%') return -1;
		index += 1;
	}
	return slots;
}

/** Refuses a declaration the renderers cannot honour. */
function classifyMenuRow(row, where) {
	if (!row || typeof row !== 'object' || Array.isArray(row))
		throw new Error(`${where}: a menu row must be a table`);
	const labelled = typeof row.i18n === 'string' && row.i18n !== '';
	const nativeCaption =
		row.caption_source === 'native' &&
		row.i18n === undefined &&
		typeof row.caption_getter === 'string' &&
		row.caption_getter !== '';
	if (row.disabled !== undefined) {
		if (typeof row.disabled !== 'boolean' || !where.startsWith('menu.top_level ')) {
			// Inert rows own their closed presentation vocabulary before the top-level gate.
			const reason =
				row.type === 'section_header'
					? 'section header needs a caption without behavior metadata'
					: row.type === 'label'
						? 'inert label needs an identity and caption without behavior metadata'
						: 'disabled is a boolean top-level presentation gate';
			throw new Error(`${where}: ${reason}`);
		}
		if (
			row.disabled &&
			(!labelled ||
				typeof row.reason_key !== 'string' ||
				row.reason_key === '' ||
				typeof row.id !== 'string' ||
				row.id === '' ||
				row.id === '---' ||
				row.unavailable !== undefined ||
				row.disabled_when !== undefined)
		)
			throw new Error(`${where}: a disabled top-level row needs its exact label and reason`);
	}
	if (row.unavailable !== undefined) {
		if (row.unavailable !== 'hide' && row.unavailable !== 'grey')
			throw new Error(`${where}: unavailable must be "hide" or "grey"`);
		const restricted =
			Array.isArray(row.platforms) &&
			row.platforms.length > 0 &&
			row.platforms.length < PLATFORMS.length &&
			new Set(row.platforms).size === row.platforms.length &&
			Array.from(row.platforms).every((platform) => PLATFORMS.includes(platform));
		if (!restricted)
			throw new Error(`${where}: unavailable needs platforms that leave some platform out`);
		if (!ROW_TYPES.has(row.type))
			throw new Error(`${where}: unavailable needs a known menu row type`);
		if (row.unavailable === 'hide' && row.reason_key !== undefined)
			throw new Error(`${where}: a hidden row carries no reason_key`);
		if (row.unavailable === 'grey') {
			if (typeof row.reason_key !== 'string' || row.reason_key === '')
				throw new Error(`${where}: a greyed row needs its reason_key`);
			if (!labelled) throw new Error(`${where}: a greyed row needs an i18n label`);
		}
		if (
			['command', 'check', 'group'].includes(row.type) &&
			(typeof row.id !== 'string' || row.id === '' || (!labelled && !nativeCaption))
		)
			throw new Error(`${where}: unavailable needs a labelled ${row.type} identity`);
	}
	if (row.disabled_reason_key !== undefined) {
		if (typeof row.disabled_reason_key !== 'string' || row.disabled_reason_key === '')
			throw new Error(`${where}: disabled_reason_key must name a locale key`);
		if (!['command', 'check', 'toggle', 'group'].includes(row.type))
			throw new Error(
				`${where}: disabled_reason_key is read on command/check/toggle rows or identified labelled groups`
			);
		if (
			row.type === 'group' &&
			(typeof row.id !== 'string' ||
				row.id === '' ||
				!labelled ||
				!Array.isArray(row.disabled_when) ||
				row.disabled_when.length === 0 ||
				Object.keys(row.disabled_when).length !== row.disabled_when.length ||
				Array.from(row.disabled_when).some((key) => typeof key !== 'string' || key === ''))
		)
			throw new Error(
				`${where}: a reasoned group needs its identity, i18n label and nonempty disabled_when keys`
			);
		if (!Array.isArray(row.disabled_when) || row.disabled_when.length === 0)
			throw new Error(`${where}: disabled_reason_key needs the disabled_when that greys the row`);
		if (!labelled) throw new Error(`${where}: a greyed row needs an i18n label`);
	}
	if (row.disabled_reasons !== undefined) {
		// A more precise reason for the same greying: the first entry whose
		// state getter answers true replaces disabled_reason_key on the row.
		if (
			!['command', 'toggle'].includes(row.type) ||
			typeof row.disabled_reason_key !== 'string' ||
			row.disabled_reason_key === ''
		)
			throw new Error(
				`${where}: disabled_reasons refines the disabled_reason_key of a command or toggle row`
			);
		if (!Array.isArray(row.disabled_reasons) || row.disabled_reasons.length === 0)
			throw new Error(`${where}: disabled_reasons must be a nonempty array`);
		for (const entry of row.disabled_reasons) {
			if (
				!entry ||
				typeof entry !== 'object' ||
				Array.isArray(entry) ||
				Object.keys(entry).length !== 2 ||
				typeof entry.when !== 'string' ||
				entry.when === '' ||
				typeof entry.reason_key !== 'string' ||
				entry.reason_key === ''
			)
				throw new Error(
					`${where}: each disabled_reasons entry is exactly { when, reason_key } with nonempty names`
				);
		}
	}
	return row.unavailable === 'hide'
		? 'not-applicable'
		: row.unavailable === 'grey'
			? 'not-ported'
			: 'unclassified';
}

/** Validates actual canonical menu tables without projecting or writing them. */
function validateMenuAvailability(menu) {
	for (const [key, rows] of Object.entries(menu)) {
		if (!Array.isArray(rows)) continue;
		for (const row of rows) {
			if (!row || typeof row !== 'object') continue;
			const where = `menu.${key} row "${row.id || row.path || row.i18n || row.type}"`;
			classifyMenuRow(row, where);
		}
	}
}

/** Recognizes the supported value slot without crediting an escaped percent. */
function hasCaptionPlaceholder(format) {
	if (typeof format !== 'string') return false;
	for (let index = 0; index < format.length; index++) {
		if (format[index] !== '%') continue;
		if (format[index + 1] === 's') return true;
		index++;
	}
	return false;
}

/** Validates frames which order completed native objects, never provider DATA. */
function validateNativeCompositions(menu) {
	for (const [key, rows] of Object.entries(menu)) {
		if (!Array.isArray(rows) || !rows.some((row) => row?.type === 'native_content')) continue;
		const identities = new Set();
		let target;
		for (const [index, row] of rows.entries()) {
			const where = `menu.${key} completed-native row ${index}`;
			if (!row || typeof row !== 'object' || Array.isArray(row))
				throw new Error(`${where}: a physical declaration must be a table`);
			if (row.type === 'native_content') {
				if (
					Object.keys(row).some(
						(field) => !['type', 'id', 'kind', 'target', 'platforms', 'unavailable'].includes(field)
					) ||
					typeof row.id !== 'string' ||
					row.id === '' ||
					identities.has(row.id) ||
					!['image', 'boundary', 'command', 'rows'].includes(row.kind) ||
					(row.target !== undefined && (row.target !== true || row.kind !== 'rows')) ||
					(row.unavailable !== undefined && row.unavailable !== 'hide')
				)
					throw new Error(
						`${where}: completed content needs a unique identity without behavior fields`
					);
				if (
					row.platforms !== undefined &&
					(!Array.isArray(row.platforms) ||
						row.platforms.length === 0 ||
						new Set(row.platforms).size !== row.platforms.length ||
						!row.platforms.every((platform) => PLATFORMS.includes(platform)))
				)
					throw new Error(`${where}: completed content needs native platform tokens`);
				if (
					row.unavailable !== undefined &&
					(row.platforms === undefined || row.platforms.length >= PLATFORMS.length)
				)
					throw new Error(`${where}: hide requires a genuinely restricted native owner`);
				identities.add(row.id);
				if (row.target === true) {
					if (target !== undefined || index !== rows.length - 1)
						throw new Error(`${where}: one final completed slot owns the target`);
					target = row.id;
				}
			} else if (row.type === '---') {
				if (
					Object.keys(row).some(
						(field) => !['type', 'after', 'platforms', 'unavailable'].includes(field)
					) ||
					typeof row.after !== 'string' ||
					!identities.has(row.after)
				)
					throw new Error(`${where}: boundary names a preceding completed slot`);
				if (
					row.platforms !== undefined &&
					(!Array.isArray(row.platforms) ||
						row.platforms.length === 0 ||
						new Set(row.platforms).size !== row.platforms.length ||
						!row.platforms.every((platform) => PLATFORMS.includes(platform)))
				)
					throw new Error(`${where}: boundary needs native platform tokens`);
				if (
					row.unavailable !== undefined &&
					(row.unavailable !== 'hide' ||
						row.platforms === undefined ||
						row.platforms.length >= PLATFORMS.length)
				)
					throw new Error(`${where}: boundary hide requires a genuinely restricted owner`);
			} else
				throw new Error(
					`${where}: a completed frame admits only content and conditional boundaries`
				);
		}
		if (target === undefined)
			throw new Error(`menu.${key}: completed composition needs one final target`);
	}
}

// Explicit numbered scalar formats leave every percent byte literal.
function numberedCaptionFits(title) {
	return (
		typeof title === 'string' &&
		title.includes('{1}') &&
		!/[{}]/u.test(title.replaceAll('{1}', '')) &&
		!/[\x00-\x1f\x7f]/u.test(title) &&
		title.isWellFormed()
	);
}

function plainPolicyObject(value) {
	if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
	const prototype = Object.getPrototypeOf(value);
	if (prototype !== Object.prototype && prototype !== null) return false;
	return Reflect.ownKeys(value).every(
		(key) =>
			typeof key === 'string' &&
			Object.getOwnPropertyDescriptor(value, key).enumerable &&
			Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value')
	);
}

/** A translated parent consumes typed native count receipts, never a native label. */
function translatedCountPolicyFits(row) {
	const policy = row.caption_count_policy;
	const fields = ['value_getter', 'present_getter', 'visibility', 'style', 'format', 'maximum'];
	if (
		row.type !== 'group' ||
		typeof row.id !== 'string' ||
		row.id === '' ||
		typeof row.i18n !== 'string' ||
		row.i18n === '' ||
		!policy ||
		typeof policy !== 'object' ||
		!plainPolicyObject(policy) ||
		Object.keys(policy).length !== fields.length ||
		Object.keys(policy).some((field) => !fields.includes(field)) ||
		[
			'caption_source',
			'caption_format',
			'caption_getter',
			'caption_getters',
			'caption_layout',
			'caption_joiner',
			'caption_count_getter',
			'caption_count_format',
			'label_prefix'
		].some((field) => row[field] !== undefined) ||
		typeof policy.value_getter !== 'string' ||
		policy.value_getter === '' ||
		typeof policy.present_getter !== 'string' ||
		policy.present_getter === '' ||
		!Number.isSafeInteger(policy.maximum) ||
		policy.maximum < 0 ||
		typeof policy.format !== 'string' ||
		/[\x00-\x1f\x7f]/.test(policy.format) ||
		!policy.format.isWellFormed() ||
		nativeCountSlots(policy.format) !== 2
	)
		return false;
	for (const field of ['visibility', 'style']) {
		const values = policy[field];
		if (
			!plainPolicyObject(values) ||
			Object.keys(values).length !== 3 ||
			Object.keys(values).some((platform) => !PLATFORMS.includes(platform)) ||
			PLATFORMS.some(
				(platform) =>
					!(
						field === 'visibility' ? ['always', 'available', 'positive'] : ['space', 'decimal']
					).includes(values[platform])
			)
		)
			return false;
	}
	return true;
}

function validateChildTemplates(menu, captionFormat) {
	if (Object.hasOwn(menu, 'shortcut_extension_construction_ahk')) {
		const policy = menu.shortcut_extension_construction_ahk;
		const stages = [
			'admit_markers',
			'allocate_owned_menu',
			'observe_native_builder',
			'place_observed_result'
		];
		if (
			!plainPolicyObject(policy) ||
			Object.keys(policy).length !== 5 ||
			!['kind', 'platform', 'program', 'result_frame', 'append_outcomes'].every((key) =>
				Object.hasOwn(policy, key)
			) ||
			policy.kind !== 'owned_native_menu' ||
			policy.platform !== 'ahk' ||
			!Array.isArray(policy.program) ||
			policy.program.length !== stages.length ||
			new Set(policy.program).size !== stages.length ||
			policy.program.some((step) => !stages.includes(step)) ||
			stages.some(
				(step, index) =>
					index && policy.program.indexOf(stages[index - 1]) > policy.program.indexOf(step)
			) ||
			typeof policy.result_frame !== 'string' ||
			policy.result_frame === '' ||
			!Array.isArray(policy.append_outcomes) ||
			new Set(policy.append_outcomes).size !== policy.append_outcomes.length ||
			policy.append_outcomes.some((outcome) => !['failed', 'empty', 'missing'].includes(outcome))
		)
			throw new Error(
				'menu.shortcut_extension_construction_ahk needs the finite owned Menu program and original observed placement domain'
			);
	}

	if (Object.hasOwn(menu, 'hotstring_personal_file_caption')) {
		const policy = menu.hotstring_personal_file_caption;
		if (
			!plainPolicyObject(policy) ||
			Object.keys(policy).length !== 1 ||
			!Object.hasOwn(policy, 'format') ||
			typeof policy.format !== 'string' ||
			/[\x00-\x1f\x7f]/.test(policy.format) ||
			!policy.format.isWellFormed() ||
			nativeCountSlots(policy.format) !== 2
		)
			throw new Error(
				'menu.hotstring_personal_file_caption needs one literal format and two scalar slots'
			);
	}
	if (Object.hasOwn(menu, 'hotstring_personal_folder_caption')) {
		const policy = menu.hotstring_personal_folder_caption;
		if (
			!plainPolicyObject(policy) ||
			Object.keys(policy).length !== 2 ||
			!['positive_format', 'nonpositive_format'].every(
				(key) =>
					Object.hasOwn(policy, key) &&
					typeof policy[key] === 'string' &&
					!/[\x00-\x1f\x7f]/.test(policy[key]) &&
					policy[key].isWellFormed()
			) ||
			nativeCountSlots(policy.positive_format) !== 2 ||
			nativeCountSlots(policy.nonpositive_format) !== 1
		)
			throw new Error(
				'menu.hotstring_personal_folder_caption needs exact positive two-slot and nonpositive one-slot formats'
			);
	}
	validateNativeCompositions(menu);
	function inertCaptionFits(row) {
		if (row.caption_getter === undefined && row.caption_getters === undefined) return true;
		if (typeof captionFormat !== 'function') return false;
		try {
			const title = captionFormat(row.i18n);
			if (row.caption_format !== undefined)
				return row.caption_format === 'numbered' && numberedCaptionFits(title);
			if (row.caption_getters !== undefined) {
				const slots = typeof title === 'string' && title.match(/%%|%s|%/g);
				return (
					Array.isArray(row.caption_getters) &&
					slots !== false &&
					(slots || []).every((slot) => slot !== '%') &&
					(slots || []).filter((slot) => slot === '%s').length === row.caption_getters.length
				);
			}
			if (row.caption_layout !== undefined)
				return typeof title === 'string' && title !== '' && !hasCaptionPlaceholder(title);
			return hasCaptionPlaceholder(title);
		} catch {
			return false;
		}
	}
	function inertPresentation(key, rowId, checking = new Set()) {
		const rows = menu[key];
		if (!Array.isArray(rows) || rows.length === 0 || checking.has(key)) return false;
		if (rowId !== undefined && rows.filter((row) => row?.id === rowId).length !== 1) return false;
		checking.add(key);
		for (const row of rows) {
			if (!row || typeof row !== 'object' || Array.isArray(row)) return false;
			let fields;
			if (row.type === 'include') {
				fields = ['type', 'section', 'row_id'];
				if (
					typeof row.section !== 'string' ||
					row.section === '' ||
					(row.row_id !== undefined && (typeof row.row_id !== 'string' || row.row_id === '')) ||
					!inertPresentation(row.section, row.row_id, checking)
				)
					return false;
			} else if (row.type === '---') {
				fields = ['type', 'platforms', 'unavailable'];
				if (row.unavailable !== undefined && row.unavailable !== 'hide') return false;
			} else if (row.type === 'label' || row.type === 'section_header') {
				fields = ['type', 'id', 'i18n', 'platforms', 'unavailable'];
				if (
					typeof row.i18n !== 'string' ||
					row.i18n === '' ||
					(row.id !== undefined && (typeof row.id !== 'string' || row.id === '')) ||
					(row.type === 'label' && row.id === undefined)
				)
					return false;
				if (row.type === 'section_header') {
					fields.push('reason_key');
					if (row.unavailable !== undefined && !['hide', 'grey'].includes(row.unavailable))
						return false;
					if (row.unavailable === 'grey' && row.reason_key === undefined) return false;
					if (
						row.reason_key !== undefined &&
						(typeof row.reason_key !== 'string' ||
							row.reason_key === '' ||
							row.unavailable === 'hide')
					)
						return false;
				} else if (row.unavailable !== undefined && row.unavailable !== 'hide') return false;
			} else return false;
			if (Object.keys(row).some((field) => !fields.includes(field))) return false;
			if (
				row.platforms !== undefined &&
				(!Array.isArray(row.platforms) ||
					row.platforms.length === 0 ||
					new Set(row.platforms).size !== row.platforms.length ||
					!row.platforms.every((platform) => PLATFORMS.includes(platform)))
			)
				return false;
		}
		checking.delete(key);
		return true;
	}
	for (const [key, rows] of Object.entries(menu)) {
		if (!Array.isArray(rows)) continue;
		for (const row of rows) {
			if (row.caption_count_policy !== undefined && !translatedCountPolicyFits(row))
				throw new Error(
					`menu.${key}: translated count needs a closed group policy and typed receipt identities`
				);
			if (Object.hasOwn(row, 'label_prefix')) {
				if (
					row.type !== 'command' ||
					typeof row.id !== 'string' ||
					row.id === '' ||
					typeof row.i18n !== 'string' ||
					row.i18n === '' ||
					typeof row.label_prefix !== 'string' ||
					/[\x00-\x1f\x7f]/.test(row.label_prefix) ||
					Buffer.from(row.label_prefix, 'utf8').toString('utf8') !== row.label_prefix
				)
					throw new Error(`menu.${key}: literal label_prefix needs a command and plain Unicode`);
			}
			if (row.caption_layout !== undefined || row.caption_joiner !== undefined) {
				if (
					!['label', 'command', 'group'].includes(row.type) ||
					!['prefix', 'suffix'].includes(row.caption_layout) ||
					typeof row.caption_joiner !== 'string' ||
					/[\x00-\x1f\x7f]/.test(row.caption_joiner) ||
					typeof row.caption_getter !== 'string' ||
					row.caption_getter === '' ||
					(row.type !== 'label' && !inertCaptionFits(row))
				)
					throw new Error(
						`menu.${key}: caption layout needs an inert label, literal joiner and getter`
					);
			}
			const where = `menu.${key} row "${row.id || row.type}"`;
			if (row.on_refusal !== undefined && row.type !== 'include')
				throw new Error(`${where}: on_refusal belongs to an inert presentation include`);
			if (row.type === 'include') {
				if (
					row.on_refusal !== undefined &&
					(row.on_refusal !== 'omit_presentation' || !inertPresentation(row.section, row.row_id))
				)
					throw new Error(`${where}: omission requires an exclusively inert presentation target`);
				if (typeof row.section !== 'string' || !Array.isArray(menu[row.section]))
					throw new Error(`${where}: include needs an existing menu section`);
				if (
					Object.keys(row).some(
						(field) => !['type', 'section', 'row_id', 'present_when', 'on_refusal'].includes(field)
					)
				)
					throw new Error(`${where}: include only composes an existing section`);
				if (
					row.row_id !== undefined &&
					(typeof row.row_id !== 'string' ||
						row.row_id === '' ||
						menu[row.section].filter((item) => item.id === row.row_id).length !== 1)
				)
					throw new Error(`${where}: include row_id needs one exact direct declared identity`);
				if (
					row.present_when !== undefined &&
					(typeof row.present_when !== 'string' || row.present_when === '')
				)
					throw new Error(`${where}: include present_when needs a named boolean getter`);
			}
			if (
				row.type === 'label' &&
				(typeof row.id !== 'string' ||
					row.id === '' ||
					typeof row.i18n !== 'string' ||
					row.i18n === '' ||
					!inertCaptionFits(row) ||
					(row.unavailable !== undefined && row.unavailable !== 'hide') ||
					Object.keys(row).some(
						(field) =>
							![
								'type',
								'id',
								'i18n',
								'platforms',
								'unavailable',
								'caption_getter',
								'caption_getters',
								'caption_layout',
								'caption_joiner'
							].includes(field)
					))
			)
				throw new Error(
					`${where}: inert label needs an identity and caption without behavior metadata`
				);
			if (
				row.type === 'section_header' &&
				((row.id !== undefined && (typeof row.id !== 'string' || row.id === '')) ||
					(row.caption_getter !== undefined && (typeof row.id !== 'string' || row.id === '')) ||
					typeof row.i18n !== 'string' ||
					row.i18n === '' ||
					!inertCaptionFits(row) ||
					(row.unavailable !== undefined && !['hide', 'grey'].includes(row.unavailable)) ||
					(row.reason_key !== undefined &&
						(typeof row.reason_key !== 'string' || row.reason_key === '')) ||
					Object.keys(row).some(
						(field) =>
							![
								'type',
								'id',
								'i18n',
								'platforms',
								'unavailable',
								'reason_key',
								'caption_getter'
							].includes(field)
					))
			)
				throw new Error(`${where}: section header needs a caption without behavior metadata`);
			if (
				row.caption_format !== undefined &&
				(row.caption_format !== 'numbered' ||
					!['command', 'group'].includes(row.type) ||
					typeof row.id !== 'string' ||
					row.id === '' ||
					typeof row.i18n !== 'string' ||
					row.i18n === '' ||
					typeof row.caption_getter !== 'string' ||
					row.caption_getter === '' ||
					row.caption_getters !== undefined ||
					row.caption_source !== undefined ||
					row.caption_layout !== undefined ||
					row.caption_joiner !== undefined ||
					row.label_prefix !== undefined ||
					row.reason_key !== undefined ||
					row.disabled_reason_key !== undefined ||
					!inertCaptionFits(row))
			)
				throw new Error(
					`${where}: numbered caption needs one named scalar getter and an original {1} command or group format`
				);
			if (
				row.caption_source !== undefined &&
				(row.caption_source !== 'native' ||
					!['check', 'group'].includes(row.type) ||
					row.i18n !== undefined ||
					typeof row.id !== 'string' ||
					row.id === '' ||
					typeof row.caption_getter !== 'string' ||
					row.caption_getter === '' ||
					row.caption_getters !== undefined ||
					row.caption_layout !== undefined ||
					row.caption_joiner !== undefined ||
					row.label_prefix !== undefined ||
					row.reason_key !== undefined ||
					row.disabled_reason_key !== undefined ||
					row.unavailable !== 'hide')
			)
				throw new Error(
					`${where}: native caption needs a record check or group without translation or decoration metadata`
				);
			if (
				(row.caption_count_getter !== undefined || row.caption_count_format !== undefined) &&
				(row.type !== 'group' ||
					row.caption_source !== 'native' ||
					typeof row.caption_count_getter !== 'string' ||
					row.caption_count_getter === '' ||
					typeof row.caption_count_format !== 'string' ||
					/[\x00-\x1f\x7f]/.test(row.caption_count_format) ||
					nativeCountSlots(row.caption_count_format) !== 2)
			)
				throw new Error(
					`${where}: native count captions need a group and two ordered scalar slots`
				);
			if (
				row.icon_getter !== undefined &&
				(row.type !== 'group' ||
					typeof row.icon_getter !== 'string' ||
					row.icon_getter === '' ||
					!Array.isArray(row.platforms) ||
					row.platforms.length !== 1 ||
					row.platforms[0] !== 'ahk')
			)
				throw new Error(`${where}: native group icons need an explicit Windows getter`);
			if (
				row.caption_getters !== undefined &&
				(!['command', 'check', 'group', 'label'].includes(row.type) ||
					typeof row.id !== 'string' ||
					row.id === '' ||
					typeof row.i18n !== 'string' ||
					row.i18n === '' ||
					row.caption_getter !== undefined ||
					row.caption_source !== undefined ||
					row.caption_layout !== undefined ||
					row.caption_joiner !== undefined ||
					!Array.isArray(row.caption_getters) ||
					row.caption_getters.length === 0 ||
					Object.keys(row.caption_getters).length !== row.caption_getters.length ||
					!Array.from({ length: row.caption_getters.length }, (_, index) => index).every(
						(index) =>
							Object.hasOwn(row.caption_getters, index) &&
							typeof row.caption_getters[index] === 'string' &&
							row.caption_getters[index] !== ''
					) ||
					!inertCaptionFits(row))
			)
				throw new Error(
					`${where}: caption_getters needs ordered named values and a translated row identity`
				);
			if (
				row.caption_getter !== undefined &&
				row.caption_source !== 'native' &&
				(!['command', 'check', 'group', 'label', 'section_header'].includes(row.type) ||
					typeof row.caption_getter !== 'string' ||
					row.caption_getter === '' ||
					typeof row.id !== 'string' ||
					row.id === '' ||
					typeof row.i18n !== 'string' ||
					row.i18n === '')
			)
				throw new Error(
					`${where}: caption_getter needs a labelled command, check or group identity, or a labelled inert label or section header`
				);
		}
	}
	const visiting = new Set();
	const visited = new Set();
	function visit(key) {
		if (visiting.has(key)) throw new Error(`menu.${key}: cyclic child-template include`);
		if (visited.has(key)) return;
		visiting.add(key);
		for (const row of menu[key]) if (row.type === 'include') visit(row.section);
		visiting.delete(key);
		visited.add(key);
	}
	for (const [key, rows] of Object.entries(menu)) if (Array.isArray(rows)) visit(key);
}

module.exports = {
	classifyMenuRow,
	validateMenuAvailability,
	validateChildTemplates,
	validateNativeCompositions
};

// One finite source reader edge for the existing owned Windows construction.
// These previously reviewed complete bodies authenticate its actual route;
// they are not a caption oracle, an arbitrary-file exemption or native credit.
const shortcutReaderRendererOwners = {
	_MR_DeclaredReplayGroupIdentity:
		'_MR_DeclaredReplayGroupIdentity(Item, ManifestKey) {\n\tif _MR_Get(Item, "type") != "group" || Type(_MR_Get(Item, "i18n")) != "String" || _MR_Get(Item, "i18n") == ""\n\t\treturn ""\n\tfor Field in ["caption_source", "caption_getters", "caption_getter", "caption_format",\n\t\t"caption_layout", "caption_joiner", "label_prefix"] {\n\t\tif Item.Has(Field)\n\t\t\treturn ""\n\t}\n\tif Item.Has("caption_count_policy") && !_MR_TranslatedCountPolicy(Item)\n\t\treturn ""\n\treturn _MR_ReplayIdentity(ManifestKey, _MR_Get(Item, "id"), "container")\n}\n',
	_MR_ReplayIdentity:
		'_MR_ReplayIdentity(ManifestKey, RowId, Kind := "command", Value := unset) {\n\tParts := [ManifestKey, RowId, Kind]\n\tif IsSet(Value) {\n\t\tif !(Value is String || Value is Integer || Value is Float)\n\t\t\tthrow TypeError("A menu replay choice requires a scalar value.")\n\t\tParts.Push(Type(Value), String(Value))\n\t}\n\tKey := ""\n\tfor Index, Part in Parts {\n\t\tif !(Part is String) || (Index <= 3 && Part == "")\n\t\t\tthrow ValueError("A menu replay identity requires nonempty canonical parts.")\n\t\tKey .= StrLen(Part) . ":" . Part\n\t}\n\treturn Key\n}\n',
	MenuRenderer_ConstructObservedMenu:
		'MenuRenderer_ConstructObservedMenu(RecipeKey, ExtId, ExtName, ObserveNative, OwnedMenus) {\n\tstatic Entry := MenuRenderer_ConstructObservedMenu, Guard := _MR_DeclaredParentCallable\n\tstatic RootReader := _MR_GetManifestRoot, Loader := _MM_GetManifestRoot, Snapshot := _MR_ReasonedGroupSnapshot\n\tstatic SourceCurrent := _MR_ReasonedGroupCurrent, TemplateOwner := MenuRenderer_TemplateRows\n\tstatic Admission := _MR_AppendTemplateRowsAdmitted, Append := MenuRenderer_AppendTemplate\n\tstatic Constructor := Menu, ConstructorOwner := _MR_FrameNativeConstructorCurrent\n\tstatic NativeObserver := _SC_ObserveExtensionMenu\n\tif RecipeKey != "shortcut_extension_construction_ahk" || !(OwnedMenus is Array)\n\t\t|| ObserveNative != NativeObserver || NativeObserver != _SC_ObserveExtensionMenu\n\t\t|| Object.Prototype.HasOwnProp.Call(Guard, "Call") || !_MR_DeclaredParentCallable(ObserveNative)\n\t\treturn false\n\tOwnersLive() {\n\t\tif Guard != _MR_DeclaredParentCallable || Object.Prototype.HasOwnProp.Call(Guard, "Call")\n\t\t\treturn false\n\t\tfor Pair in [[Entry, MenuRenderer_ConstructObservedMenu], [RootReader, _MR_GetManifestRoot], [Loader, _MM_GetManifestRoot],\n\t\t\t[Snapshot, _MR_ReasonedGroupSnapshot], [SourceCurrent, _MR_ReasonedGroupCurrent],\n\t\t\t[ConstructorOwner, _MR_FrameNativeConstructorCurrent]]\n\t\t\tif Pair[1] != Pair[2] || !Guard.Call(Pair[1])\n\t\t\t\treturn false\n\t\treturn ObserveNative == NativeObserver && NativeObserver == _SC_ObserveExtensionMenu && Guard.Call(ObserveNative)\n\t}\n\tif !OwnersLive()\n\t\treturn false\n\tRoot := RootReader.Call()\n\tif !(Root is Map) || ObjGetBase(Root) != Map.Prototype\n\t\treturn false\n\tfor Name in ObjOwnProps(Root)\n\t\treturn false\n\tif !Root.Has(RecipeKey)\n\t\treturn false\n\tRecipe := Root[RecipeKey]\n\tif !(Recipe is Map) || ObjGetBase(Recipe) != Map.Prototype\n\t\treturn false\n\tfor Name in ObjOwnProps(Recipe)\n\t\treturn false\n\tif Recipe.Count != 5 || Recipe.Get("kind", "") != "owned_native_menu"\n\t\t|| Recipe.Get("platform", "") != "ahk" || !(Recipe.Get("program", false) is Array)\n\t\t|| Type(Recipe.Get("result_frame", false)) != "String" || Recipe["result_frame"] == ""\n\t\t|| !(Recipe.Get("append_outcomes", false) is Array)\n\t\treturn false\n\tProgram := Recipe["program"], Outcomes := Recipe["append_outcomes"]\n\tif ObjGetBase(Program) != Array.Prototype || ObjGetBase(Outcomes) != Array.Prototype\n\t\t|| ObjGetBase(OwnedMenus) != Array.Prototype\n\t\treturn false\n\tfor Container in [Program, Outcomes, OwnedMenus]\n\t\tfor Name in ObjOwnProps(Container)\n\t\t\treturn false\n\tif Program.Length != 4\n\t\treturn false\n\tFields := Map("kind", true, "platform", true, "program", true, "result_frame", true, "append_outcomes", true)\n\tfor Field in Recipe\n\t\tif !Fields.Has(Field)\n\t\t\treturn false\n\tSteps := Map("admit_markers", true, "allocate_owned_menu", true, "observe_native_builder", true, "place_observed_result", true)\n\tResults := Map("failed", true, "empty", true, "missing", true, "populated", true)\n\tPositions := Map()\n\tfor Index, Step in Program {\n\t\tif Type(Step) != "String" || !Steps.Has(Step) || Positions.Has(Step)\n\t\t\treturn false\n\t\tPositions[Step] := Index\n\t}\n\tif Positions.Count != 4 || Positions["admit_markers"] > Positions["allocate_owned_menu"]\n\t\t|| Positions["allocate_owned_menu"] > Positions["observe_native_builder"]\n\t\t|| Positions["observe_native_builder"] > Positions["place_observed_result"]\n\t\treturn false\n\tEligible := Map()\n\tfor Outcome in Outcomes {\n\t\tif Type(Outcome) != "String" || !Results.Has(Outcome) || Outcome == "populated" || Eligible.Has(Outcome)\n\t\t\treturn false\n\t\tEligible[Outcome] := true\n\t}\n\tRecipeSource := Snapshot.Call(Recipe)\n\tif !RecipeSource || !OwnersLive()\n\t\treturn false\n\tCurrent() {\n\t\tif !OwnersLive() || RootReader.Call() != Root || ObjGetBase(Root) != Map.Prototype\n\t\t\treturn false\n\t\tfor Name in ObjOwnProps(Root)\n\t\t\treturn false\n\t\treturn Root.Has(RecipeKey) && Root[RecipeKey] == Recipe && SourceCurrent.Call(RecipeSource)\n\t}\n\tObserved := "populated", Native := false\n\tState := Map("shortcut_extension_name", (*) => ExtId,\n\t\t"shortcut_extension_builder_failed", (*) => Observed == "failed",\n\t\t"shortcut_extension_builder_empty", (*) => Observed == "empty",\n\t\t"shortcut_extension_builder_missing", (*) => Observed == "missing")\n\tfor Step in Program {\n\t\tif !Current()\n\t\t\tthrow Error("Shortcut extension construction source was withdrawn")\n\t\tswitch Step {\n\t\tcase "admit_markers":\n\t\t\tif TemplateOwner != MenuRenderer_TemplateRows || Admission != _MR_AppendTemplateRowsAdmitted\n\t\t\t\t|| !Guard.Call(TemplateOwner) || !Guard.Call(Admission)\n\t\t\t\treturn false\n\t\t\tErrorRows := TemplateOwner.Call("shortcut_extension_error_frame", Map(), State, Map())\n\t\t\tif !Current() || !Guard.Call(TemplateOwner) || !Guard.Call(Admission)\n\t\t\t\treturn false\n\t\t\tEmptyRows := TemplateOwner.Call("shortcut_extension_empty_frame", Map(), Map(), Map())\n\t\t\tif !Current() || TemplateOwner != MenuRenderer_TemplateRows || Admission != _MR_AppendTemplateRowsAdmitted\n\t\t\t\t|| !Guard.Call(TemplateOwner) || !Guard.Call(Admission)\n\t\t\t\treturn false\n\t\t\tif !(ErrorRows is Array) || ErrorRows.Length == 0 || !Admission.Call(ErrorRows, 1, Map())\n\t\t\t\t|| !(EmptyRows is Array) || EmptyRows.Length == 0 || !Admission.Call(EmptyRows, 1, Map())\n\t\t\t\treturn false\n\t\t\tif !Current() || TemplateOwner != MenuRenderer_TemplateRows || !Guard.Call(TemplateOwner)\n\t\t\t\treturn false\n\t\t\tResultRows := TemplateOwner.Call(Recipe["result_frame"], Map(), State, Map())\n\t\t\tif !(ResultRows is Array) || ResultRows.Length != 0 || !Current()\n\t\t\t\treturn false\n\t\tcase "allocate_owned_menu":\n\t\t\tif !ConstructorOwner.Call(Constructor)\n\t\t\t\treturn false\n\t\t\tNative := Constructor.Call()\n\t\t\tOwnedMenus.Push(Native)\n\t\tcase "observe_native_builder":\n\t\t\tObserved := ObserveNative.Call(ExtId, ExtName, Native)\n\t\t\tif Type(Observed) != "String" || !Results.Has(Observed)\n\t\t\t\tthrow Error("Shortcut extension native observation was refused")\n\t\tcase "place_observed_result":\n\t\t\tif Eligible.Has(Observed) {\n\t\t\t\tif Append != MenuRenderer_AppendTemplate || !Guard.Call(Append)\n\t\t\t\t\tthrow Error("Shortcut extension result placement owner was withdrawn")\n\t\t\t\tif Append.Call(Native, Recipe["result_frame"], Map(), State, Map()) == 0\n\t\t\t\t\tthrow Error(Observed == "missing"\n\t\t\t\t\t\t? "Shortcut extension empty marker was withdrawn before publication"\n\t\t\t\t\t\t: "Shortcut extension error marker was withdrawn during its native builder")\n\t\t\t}\n\t\t}\n\t}\n\treturn Native\n}\n',
	MenuRenderer_TemplateRows:
		'MenuRenderer_TemplateRows(ManifestKey, Commands, StateGetters, Children) {\n\treturn _MR_TemplateRows(ManifestKey, Commands, StateGetters, Children, Map())\n}\n',
	MenuRenderer_AppendTemplate:
		'MenuRenderer_AppendTemplate(TargetMenu, ManifestKey, Commands, StateGetters, Children, &Admitted := unset) {\n\tAdmitted := false\n\tif !(TargetMenu is Menu) || Type(ManifestKey) != "String" || ManifestKey == ""\n\t\treturn 0\n\ttry {\n\t\tRows := MenuRenderer_TemplateRows(ManifestKey, Commands, StateGetters, Children)\n\t\tif !_MR_AppendTemplateRowsAdmitted(Rows, 1, Map())\n\t\t\treturn 0\n\t} catch {\n\t\treturn 0\n\t}\n\tAdmitted := true\n\treturn _MR_RenderRows(TargetMenu, Rows, ManifestKey, 1)\n}\n',
	_MR_GetMenuDef:
		'_MR_GetMenuDef(Key) {\n\tRoot := _MR_GetManifestRoot()\n\tif (Root == false) {\n\t\treturn []\n\t}\n\tif !(Root.Has(Key)) {\n\t\ttry LoggerWarn("MenuRenderer", "menu key \'{1}\' not found in manifest.", Key)\n\t\treturn []\n\t}\n\tArr := Root[Key]\n\treturn (Arr is Array) ? Arr : []\n}\n',
	_MR_GetManifestRoot: '_MR_GetManifestRoot() {\n\treturn _MM_GetManifestRoot()\n}\n',
	_MR_DeclaredParentCallable:
		'_MR_DeclaredParentCallable(Owner) {\n\treturn (Owner is Func || Owner is BoundFunc)\n\t\t&& !Object.Prototype.HasOwnProp.Call(Owner, "Call")\n}\n',
	_MR_ReasonedGroupSnapshot:
		'_MR_ReasonedGroupSnapshot(Value, Seen := unset) {\n\tif !(Value is Map) && !(Value is Array)\n\t\treturn Map("value", Value)\n\tif ObjGetBase(Value) != (Value is Map ? Map.Prototype : Array.Prototype)\n\t\treturn false\n\tfor Name in ObjOwnProps(Value)\n\t\treturn false\n\tSeen := IsSet(Seen) ? Seen : Map()\n\tIdentity := ObjPtr(Value)\n\tif Seen.Has(Identity)\n\t\treturn Seen[Identity]\n\tReceipt := Map("value", Value, "fields", Map(), "size", Value is Map ? Value.Count : Value.Length)\n\tSeen[Identity] := Receipt\n\tif Value is Array {\n\t\tloop Value.Length\n\t\t\tif !Value.Has(A_Index)\n\t\t\t\treturn false\n\t}\n\tfor Key, Field in Value {\n\t\tCaptured := _MR_ReasonedGroupSnapshot(Field, Seen)\n\t\tif !Captured\n\t\t\treturn false\n\t\tReceipt["fields"][Key] := Captured\n\t}\n\treturn Receipt\n}\n',
	_MR_ReasonedGroupCurrent:
		'_MR_ReasonedGroupCurrent(Receipt, Seen := unset) {\n\tif !(Receipt is Map)\n\t\treturn false\n\tif !Receipt.Has("fields")\n\t\treturn true\n\tValue := Receipt["value"]\n\tif ObjGetBase(Value) != (Value is Map ? Map.Prototype : Array.Prototype)\n\t\treturn false\n\tfor Name in ObjOwnProps(Value)\n\t\treturn false\n\tif (Value is Map ? Value.Count : Value.Length) != Receipt["size"]\n\t\treturn false\n\tSeen := IsSet(Seen) ? Seen : Map()\n\tIdentity := ObjPtr(Receipt)\n\tif Seen.Has(Identity)\n\t\treturn true\n\tSeen[Identity] := true\n\tfor Key, Captured in Receipt["fields"] {\n\t\tif !Value.Has(Key) || Type(Value[Key]) != Type(Captured["value"])\n\t\t\t|| !(Value[Key] == Captured["value"]) || !_MR_ReasonedGroupCurrent(Captured, Seen)\n\t\t\treturn false\n\t}\n\treturn true\n}\n',
	_MR_FrameNativeConstructorCurrent:
		'_MR_FrameNativeConstructorCurrent(Constructor) {\n\tstatic NativeClass := Menu\n\tstatic NativeFactory := Object.Prototype.GetOwnPropDesc.Call(Menu, "Call").Call\n\tstatic NameGetter := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, "Name").Get\n\tstatic BuiltInGetter := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, "IsBuiltIn").Get\n\tSourceLive() {\n\t\tif Constructor != NativeClass || NativeClass != Menu\n\t\t\t|| !Object.Prototype.HasOwnProp.Call(NativeClass, "Call")\n\t\t\treturn false\n\t\tDescriptor := Object.Prototype.GetOwnPropDesc.Call(NativeClass, "Call")\n\t\tif !Object.Prototype.HasOwnProp.Call(Descriptor, "Call") || Descriptor.Call != NativeFactory\n\t\t\treturn false\n\t\tfor Name in ObjOwnProps(Descriptor)\n\t\t\tif Name != "Call"\n\t\t\t\treturn false\n\t\tif !(NativeFactory is Func) || ObjGetBase(NativeFactory) != Func.Prototype\n\t\t\treturn false\n\t\tfor Name in ObjOwnProps(NativeFactory)\n\t\t\treturn false\n\t\tfor Name, Getter in Map("Name", NameGetter, "IsBuiltIn", BuiltInGetter) {\n\t\t\tif !Object.Prototype.HasOwnProp.Call(Func.Prototype, Name)\n\t\t\t\treturn false\n\t\t\tReaderDescriptor := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, Name)\n\t\t\tif !Object.Prototype.HasOwnProp.Call(ReaderDescriptor, "Get") || ReaderDescriptor.Get != Getter\n\t\t\t\treturn false\n\t\t\tfor Field in ObjOwnProps(ReaderDescriptor)\n\t\t\t\tif Field != "Get"\n\t\t\t\t\treturn false\n\t\t\tif !(Getter is Func) || ObjGetBase(Getter) != Func.Prototype\n\t\t\t\treturn false\n\t\t\tfor Field in ObjOwnProps(Getter)\n\t\t\t\treturn false\n\t\t}\n\t\treturn true\n\t}\n\tif !SourceLive()\n\t\treturn false\n\tBuiltIn := BuiltInGetter.Call(NativeFactory)\n\tif !SourceLive() || !BuiltIn\n\t\treturn false\n\tNativeFactoryName := NameGetter.Call(NativeFactory)\n\treturn SourceLive() && NativeFactoryName == "Menu.Call"\n}\n',
	_MR_AppendTemplateRowsAdmitted:
		'_MR_AppendTemplateRowsAdmitted(Rows, Depth, Active) {\n\tglobal MR_MAX_LIST_DEPTH\n\tif !(Rows is Array) || ObjGetBase(Rows) != Array.Prototype || Depth > MR_MAX_LIST_DEPTH\n\t\treturn false\n\tfor PropertyName in ObjOwnProps(Rows)\n\t\treturn false\n\tIdentity := ObjPtr(Rows)\n\tif Active.Has(Identity)\n\t\treturn false\n\tActive[Identity] := true\n\tFields := Map("label", true, "separator", true, "action", true, "items", true,\n\t\t"submenu", true, "checked", true, "disabled", true, "disabled_reason_key", true, "icon", true, "replay_id", true, "replay_group", true)\n\tloop Rows.Length {\n\t\tif !Rows.Has(A_Index)\n\t\t\treturn false\n\t\tRow := Rows[A_Index]\n\t\tif !(Row is Map) || ObjGetBase(Row) != Map.Prototype\n\t\t\treturn false\n\t\tfor PropertyName in ObjOwnProps(Row)\n\t\t\treturn false\n\t\tfor Field in Row {\n\t\t\tif Type(Field) != "String" || !Fields.Has(Field)\n\t\t\t\treturn false\n\t\t}\n\t\tfor BooleanKey in ["separator", "checked", "disabled"] {\n\t\t\tif Row.Has(BooleanKey) && (Type(Row[BooleanKey]) != "Integer"\n\t\t\t\t|| (Row[BooleanKey] != 0 && Row[BooleanKey] != 1))\n\t\t\t\treturn false\n\t\t}\n\t\tfor ReplayField in ["replay_id", "replay_group"] {\n\t\t\tif Row.Has(ReplayField) && (Type(Row[ReplayField]) != "String" || Row[ReplayField] == "")\n\t\t\t\treturn false\n\t\t}\n\t\tif (Row.Has("replay_id") && !Row.Has("action")) || (Row.Has("replay_group") && !Row.Has("items") && !Row.Has("submenu"))\n\t\t\treturn false\n\t\tif Row.Has("icon") && Type(Row["icon"]) != "String"\n\t\t\treturn false\n\t\tif Row.Has("disabled_reason_key") && Type(Row["disabled_reason_key"]) != "String"\n\t\t\treturn false\n\t\tif Row.Has("separator") && Row["separator"] == 1 {\n\t\t\tif Row.Count != 1\n\t\t\t\treturn false\n\t\t\tcontinue\n\t\t}\n\t\tif !Row.Has("label") || Type(Row["label"]) != "String" || Row["label"] == ""\n\t\t\treturn false\n\t\tVariants := (Row.Has("items") ? 1 : 0) + (Row.Has("submenu") ? 1 : 0) + (Row.Has("action") ? 1 : 0)\n\t\tif Variants > 1\n\t\t\treturn false\n\t\tif Row.Has("items") && !_MR_AppendTemplateRowsAdmitted(Row["items"], Depth + 1, Active)\n\t\t\treturn false\n\t\tif Row.Has("submenu") && !(Row["submenu"] is Menu)\n\t\t\treturn false\n\t\tif Row.Has("action") && !(Row["action"] is Func || Row["action"] is MenuStartupUiCommand)\n\t\t\treturn false\n\t}\n\tActive.Delete(Identity)\n\treturn true\n}\n',
	_MR_TemplateRows:
		'_MR_TemplateRows(ManifestKey, Commands, StateGetters, Children, Visiting, StatusDefinition := unset, RowId := unset) {\n\tDef := IsSet(StatusDefinition) ? StatusDefinition : _MR_GetMenuDef(ManifestKey)\n\tif IsSet(RowId) {\n\t\tSelected := false\n\t\tMatches := 0\n\t\tfor Item in Def {\n\t\t\tif _MR_Get(Item, "id") == RowId {\n\t\t\t\tSelected := Item\n\t\t\t\tMatches += 1\n\t\t\t}\n\t\t}\n\t\tif Type(RowId) != "String" || RowId == "" || Matches != 1 {\n\t\t\ttry LoggerError("MenuRenderer", "Missing or ambiguous child-template row \'{1}.{2}\' — rows refused.", ManifestKey, RowId)\n\t\t\treturn false\n\t\t}\n\t\tDef := [Selected]\n\t}\n\tif Visiting.Has(ManifestKey) || Def.Length == 0 {\n\t\ttry LoggerError("MenuRenderer", "Missing or cyclic child template \'{1}\' — provider rows refused.", ManifestKey)\n\t\treturn false\n\t}\n\tVisiting[ManifestKey] := true\n\tRows := []\n\tfor Item in Def {\n\t\tif !_MR_CommandLiteralPrefix(Item, &Prefix)\n\t\t\treturn false\n\t\tif Item.Has("caption_count_policy") && !_MR_TranslatedCountPolicy(Item)\n\t\t\treturn false\n\t\tif !_MR_CaptionLayoutMetadata(Item) || !_MR_CaptionVectorMetadata(Item, StateGetters, _MR_IsForAhk(Item))\n\t\t\t|| (Item.Has("caption_format") && _MR_IsForAhk(Item) && !_MR_ReadNumberedCaption(Item, StateGetters, &NumberedCaption))\n\t\t\t|| (Item.Has("caption_source") && _MR_IsForAhk(Item) && !_MR_ReadNativeCaption(Item, StateGetters, &NativeCaption))\n\t\t\treturn false\n\t\tif Item.Has("on_refusal") && _MR_Get(Item, "type") != "include" {\n\t\t\ttry LoggerError("MenuRenderer", "Invalid presentation omission policy in \'{1}\' — rows refused.", ManifestKey)\n\t\t\treturn false\n\t\t}\n\t\tif !_MR_IsForAhk(Item) && !(_MR_Get(Item, "type") == "section_header" && _MR_Get(Item, "unavailable") == "grey")\n\t\t\tcontinue\n\t\tItemType := _MR_Get(Item, "type")\n\t\tId := _MR_Get(Item, "id")\n\t\tif ItemType == "include" {\n\t\t\tFields := Map("type", true, "section", true, "row_id", true, "present_when", true, "on_refusal", true)\n\t\t\tfor Field in Item\n\t\t\t\tif !Fields.Has(Field)\n\t\t\t\t\treturn false\n\t\t\tSection := _MR_Get(Item, "section")\n\t\t\tif Type(Section) != "String" || Section == ""\n\t\t\t\treturn false\n\t\t\tTarget := _MR_GetMenuDef(Section)\n\t\t\tOmit := Item.Has("on_refusal") && Item["on_refusal"] == "omit_presentation"\n\t\t\tif (Item.Has("on_refusal") && !Omit) || (!Omit && Target.Length == 0)\n\t\t\t\treturn false\n\t\t\tif Item.Has("row_id") {\n\t\t\t\tSelectedId := Item["row_id"]\n\t\t\t\tMatches := 0\n\t\t\t\tfor Child in Target\n\t\t\t\t\tif _MR_Get(Child, "id") == SelectedId\n\t\t\t\t\t\tMatches += 1\n\t\t\t\tif Type(SelectedId) != "String" || SelectedId == "" || Matches != 1\n\t\t\t\t\treturn false\n\t\t\t}\n\t\t\tPresent := true\n\t\t\tif Item.Has("present_when") {\n\t\t\t\tGetterKey := Item["present_when"]\n\t\t\t\tif Type(GetterKey) != "String" || GetterKey == "" || !StateGetters.Has(GetterKey)\n\t\t\t\t\t|| !HasMethod(StateGetters[GetterKey], "Call")\n\t\t\t\t\treturn false\n\t\t\t\ttry Present := StateGetters[GetterKey].Call()\n\t\t\t\tcatch\n\t\t\t\t\treturn false\n\t\t\t\tif Type(Present) != "Integer" || (Present != 0 && Present != 1)\n\t\t\t\t\treturn false\n\t\t\t}\n\t\t\tPresentationValid := !Omit || (Item.Has("row_id")\n\t\t\t\t? _MR_TemplateInertPresentation(Section, Map(), Item["row_id"])\n\t\t\t\t: _MR_TemplateInertPresentation(Section, Map()))\n\t\t\tif !PresentationValid {\n\t\t\t\ttry LoggerError("MenuRenderer", "Invalid inert presentation include \'{1}\' in \'{2}\' — presentation omitted.", Section, ManifestKey)\n\t\t\t} else if Present {\n\t\t\t\tIncluded := Item.Has("row_id")\n\t\t\t\t\t? _MR_TemplateRows(_MR_Get(Item, "section"), Commands, StateGetters, Children, Visiting, , Item["row_id"])\n\t\t\t\t\t: _MR_TemplateRows(_MR_Get(Item, "section"), Commands, StateGetters, Children, Visiting)\n\t\t\t\tif !(Included is Array)\n\t\t\t\t\treturn false\n\t\t\t\tfor Child in Included\n\t\t\t\t\tRows.Push(Child)\n\t\t\t}\n\t\t\tcontinue\n\t\t}\n\t\tif ItemType == "list" {\n\t\t\tFields := Map("type", true, "id", true, "platforms", true, "unavailable", true)\n\t\t\tfor Field in Item\n\t\t\t\tif !Fields.Has(Field)\n\t\t\t\t\treturn false\n\t\t\tSupplied := Children.Has(Id) ? _MR_TemplateNativeChildren(Id, Children[Id]) : false\n\t\t\tif !(Supplied is Array)\n\t\t\t\treturn false\n\t\t\tfor Child in Supplied\n\t\t\t\tRows.Push(Child)\n\t\t\tcontinue\n\t\t}\n\t\tif ItemType == "---"\n\t\t\tRow := Map("separator", true)\n\t\telse if IsSet(StatusDefinition) && ItemType == "label"\n\t\t\tRow := Map("label", t(Item["i18n"]), "disabled", true)\n\t\telse if ItemType == "label" {\n\t\t\tFields := Map("type", true, "id", true, "i18n", true, "platforms", true, "unavailable", true, "caption_getter", true, "caption_getters", true, "caption_layout", true, "caption_joiner", true)\n\t\t\tI18nKey := _MR_Get(Item, "i18n")\n\t\t\tUnavailable := _MR_Get(Item, "unavailable")\n\t\t\tValid := Type(Id) == "String" && Id != "" && Type(I18nKey) == "String" && I18nKey != ""\n\t\t\t\t&& (!Item.Has("unavailable") || Unavailable == "hide")\n\t\t\tValid := Valid && (!Item.Has("caption_getter") || (Type(Item["caption_getter"]) == "String"\n\t\t\t\t&& Item["caption_getter"] != "" && Type(Id) == "String" && Id != ""))\n\t\t\tfor Field in Item {\n\t\t\t\tif !Fields.Has(Field)\n\t\t\t\t\tValid := false\n\t\t\t}\n\t\t\tif !Valid {\n\t\t\t\ttry LoggerError("MenuRenderer", "Invalid inert label in template \'{1}\' — provider rows refused.", ManifestKey)\n\t\t\t\treturn false\n\t\t\t}\n\t\t\tRow := Map("label", t(I18nKey), "disabled", true)\n\t\t}\n\t\telse if ItemType == "section_header" {\n\t\t\tFields := Map("type", true, "id", true, "i18n", true, "platforms", true,\n\t\t\t\t"unavailable", true, "reason_key", true, "caption_getter", true)\n\t\t\tI18nKey := _MR_Get(Item, "i18n")\n\t\t\tUnavailable := _MR_Get(Item, "unavailable")\n\t\t\tReason := _MR_Get(Item, "reason_key")\n\t\t\tValid := (!Item.Has("id") || (Type(Id) == "String" && Id != ""))\n\t\t\t\t&& Type(I18nKey) == "String" && I18nKey != ""\n\t\t\t\t&& (!Item.Has("unavailable") || Unavailable == "hide" || Unavailable == "grey")\n\t\t\t\t&& (Unavailable != "grey" || Item.Has("reason_key"))\n\t\t\t\t&& (!Item.Has("reason_key") || (Type(Reason) == "String" && Reason != ""\n\t\t\t\t\t&& Unavailable != "hide"))\n\t\t\tValid := Valid && (!Item.Has("caption_getter") || (Type(Item["caption_getter"]) == "String"\n\t\t\t\t&& Item["caption_getter"] != "" && Type(Id) == "String" && Id != ""))\n\t\t\tfor Field in Item {\n\t\t\t\tif !Fields.Has(Field)\n\t\t\t\t\tValid := false\n\t\t\t}\n\t\t\tif !Valid {\n\t\t\t\ttry LoggerError("MenuRenderer", "Invalid section header in template \'{1}\' — provider rows refused.", ManifestKey)\n\t\t\t\treturn false\n\t\t\t}\n\t\t\tif _MR_IsForAhk(Item)\n\t\t\t\tRow := Map("label", MenuSectionTitle(t(I18nKey)), "disabled", true)\n\t\t\telse\n\t\t\t\tRow := Map("label", t(I18nKey) . " — " . _MR_ReasonHead(t(Reason)), "disabled", true)\n\t\t}\n\t\telse if ItemType == "command" {\n\t\t\tRow := MenuRenderer_CommandRow(ManifestKey, Id, Commands, StateGetters)\n\t\t\tif !(Row is Map)\n\t\t\t\treturn false\n\t\t} else if ItemType == "check" {\n\t\t\tRow := MenuRenderer_CheckRow(ManifestKey, Id, Commands, StateGetters)\n\t\t\tif !(Row is Map)\n\t\t\t\treturn false\n\t\t} else if ItemType == "group" && Children.Has(Id) && (Children[Id] is Array || HasMethod(Children[Id], "Call")) {\n\t\t\tLabel := unset\n\t\t\tif Item.Has("caption_count_policy") && !_MR_ReadTranslatedCountCaption(Item, StateGetters, &Label)\n\t\t\t\treturn false\n\t\t\tif Item.Has("caption_format") && !_MR_ReadNumberedCaption(Item, StateGetters, &Label)\n\t\t\t\treturn false\n\t\t\tif Item.Has("caption_source") && !_MR_ReadNativeCaption(Item, StateGetters, &Label)\n\t\t\t\treturn false\n\t\t\tif Item.Has("caption_layout") || Item.Has("caption_joiner") {\n\t\t\t\tif !_MR_ExplicitCaption(Item, StateGetters, &Label)\n\t\t\t\t\treturn false\n\t\t\t}\n\t\t\tItems := Children[Id] is Array ? Children[Id] : _MR_TemplateNativeChildren(Id, Children[Id])\n\t\t\tif !(Items is Array)\n\t\t\t\treturn false\n\t\t\tRow := Map("label", IsSet(Label) ? Label : t(_MR_Get(Item, "i18n")), "items", Items)\n\t\t\tReplayGroup := _MR_DeclaredReplayGroupIdentity(Item, ManifestKey)\n\t\t\tif ReplayGroup != ""\n\t\t\t\tRow["replay_group"] := ReplayGroup\n\t\t\tif Item.Has("icon_getter") {\n\t\t\t\tIconGetter := Item["icon_getter"]\n\t\t\t\tif Type(IconGetter) != "String" || IconGetter == "" || !(StateGetters is Map)\n\t\t\t\t\t|| !StateGetters.Has(IconGetter) || !HasMethod(StateGetters[IconGetter], "Call")\n\t\t\t\t\treturn false\n\t\t\t\ttry Icon := StateGetters[IconGetter].Call()\n\t\t\t\tcatch\n\t\t\t\t\treturn false\n\t\t\t\tif Type(Icon) != "String"\n\t\t\t\t\treturn false\n\t\t\t\tRow["icon"] := Icon\n\t\t\t}\n\t\t\tif Item.Has("disabled_when") && MenuRenderer_ResolveDisabledWhen(ManifestKey, Id, StateGetters) {\n\t\t\t\tRow["disabled"] := true\n\t\t\t\tif Item.Has("disabled_reason_key")\n\t\t\t\t\tRow["disabled_reason_key"] := Item["disabled_reason_key"]\n\t\t\t}\n\t\t}\n\t\telse {\n\t\t\ttry LoggerError("MenuRenderer", "Missing child data or unsupported row in template \'{1}\' — provider rows refused.", ManifestKey)\n\t\t\treturn false\n\t\t}\n\t\tif Item.Has("caption_getters") && ItemType != "command" && ItemType != "check" {\n\t\t\tif !_MR_ReadCaptionValues(Item, StateGetters, &Caption)\n\t\t\t\treturn false\n\t\t\tRow["label"] := Prefix . Caption\n\t\t}\n\t\tCaptionGetter := _MR_Get(Item, "caption_getter")\n\t\tif !Item.Has("caption_format") && !Item.Has("caption_source") && CaptionGetter != "" && !((ItemType == "command" || ItemType == "group")\n\t\t\t&& (Item.Has("caption_layout") || Item.Has("caption_joiner"))) {\n\t\t\tif !StateGetters.Has(CaptionGetter) || !HasMethod(StateGetters[CaptionGetter], "Call") {\n\t\t\t\ttry LoggerError("MenuRenderer", "Missing or invalid caption getter in template \'{1}\' — provider rows refused.", ManifestKey)\n\t\t\t\treturn false\n\t\t\t}\n\t\t\tRawTitle := t(_MR_Get(Item, "i18n"))\n\t\t\tCaptionLayout := _MR_Get(Item, "caption_layout")\n\t\t\tif ItemType == "label" || ItemType == "section_header" {\n\t\t\t\t_MR_CaptionFormat(RawTitle, "", &SourceSlot)\n\t\t\t\tValid := CaptionLayout == "" ? SourceSlot : !SourceSlot && Type(RawTitle) == "String"\n\t\t\t\t\t&& RawTitle != "" && RawTitle != _MR_Get(Item, "i18n")\n\t\t\t\tif !Valid {\n\t\t\t\t\ttry LoggerError("MenuRenderer", "Invalid inert caption format in template \'{1}\' — provider rows refused.", ManifestKey)\n\t\t\t\t\treturn false\n\t\t\t\t}\n\t\t\t}\n\t\t\tValue := CaptionLayout == "" ? StateGetters[CaptionGetter].Call() : ""\n\t\t\tTitle := ItemType == "section_header" ? Row["label"] : RawTitle\n\t\t\tif Type(Value) != "String" {\n\t\t\t\ttry LoggerError("MenuRenderer", "Invalid caption getter in template \'{1}\' — provider rows refused.", ManifestKey)\n\t\t\t\treturn false\n\t\t\t}\n\t\t\tCaption := _MR_CaptionFormat(Title, Value, &HasSlot)\n\t\t\tif CaptionLayout != "" {\n\t\t\t\tif !_MR_ExplicitCaption(Item, StateGetters, &Caption, RawTitle)\n\t\t\t\t\treturn false\n\t\t\t\tHasSlot := true\n\t\t\t}\n\t\t\tif (ItemType == "label" || ItemType == "section_header") && !HasSlot {\n\t\t\t\ttry LoggerError("MenuRenderer", "Invalid inert caption format in template \'{1}\' — provider rows refused.", ManifestKey)\n\t\t\t\treturn false\n\t\t\t}\n\t\t\tRow["label"] := Prefix . Caption\n\t\t}\n\t\tRows.Push(Row)\n\t}\n\tVisiting.Delete(ManifestKey)\n\treturn Rows\n}\n',
	_MR_ExplicitCaption:
		'_MR_ExplicitCaption(Item, Getters, &Caption, RawTitle := unset) {\n\tI18nKey := _MR_Get(Item, "i18n")\n\tCaption := IsSet(RawTitle) ? RawTitle : t(I18nKey)\n\t_MR_CaptionFormat(Caption, "", &SourceSlot)\n\tGetter := _MR_Get(Item, "caption_getter")\n\tif !_MR_CaptionLayoutMetadata(Item) || Type(_MR_Get(Item, "id")) != "String" || _MR_Get(Item, "id") == ""\n\t\t|| Type(I18nKey) != "String" || I18nKey == "" || Type(Caption) != "String" || Caption == ""\n\t\t|| Caption == I18nKey || SourceSlot || !(Getters is Map) || !Getters.Has(Getter)\n\t\t|| !HasMethod(Getters[Getter], "Call") {\n\t\ttry LoggerError("MenuRenderer", "Invalid explicit caption source \u2014 row refused.")\n\t\treturn false\n\t}\n\tValue := Getters[Getter].Call()\n\tif Type(Value) != "String" {\n\t\ttry LoggerError("MenuRenderer", "Invalid explicit caption receipt \u2014 row refused.")\n\t\treturn false\n\t}\n\tCaption := Item["caption_layout"] == "prefix" ? Caption . Item["caption_joiner"] . Value\n\t\t: Value . Item["caption_joiner"] . Caption\n\treturn true\n}\n'
};
const shortcutReaderProducerOwners = {
	_SC_ExtensionRows:
		'_SC_ExtensionRows() {\n\tglobal _ExtensionsDir\n\tExtShortcutsBaseDir := _ExtensionsDir . "\\"\n\tHasExtShortcuts := false\n\tif DirExist(ExtShortcutsBaseDir) {\n\t\tLoop Files ExtShortcutsBaseDir . "*", "D" {\n\t\t\tMenuAhkPath := A_LoopFileFullPath . "\\shortcuts\\menu.ahk"\n\t\t\tif FileExist(MenuAhkPath) {\n\t\t\t\tHasExtShortcuts := true\n\t\t\t\tbreak\n\t\t\t}\n\t\t}\n\t}\n\tRows := []\n\tif !HasExtShortcuts {\n\t\treturn Rows\n\t}\n\tBoundaryRows := MenuRenderer_TemplateRows("shortcut_extension_boundary", Map(), Map(), Map())\n\tif !(BoundaryRows is Array)\n\t\treturn []\n\tfor Row in BoundaryRows\n\t\tRows.Push(Row)\n\tOwnedMenus := [], Completed := false\n\ttry {\n\t\tLoop Files ExtShortcutsBaseDir . "*", "D" {\n\t\t\tExtId       := A_LoopFileName\n\t\t\tExtDir      := A_LoopFileFullPath\n\t\t\tMenuAhkPath := ExtDir . "\\shortcuts\\menu.ahk"\n\t\t\tif !FileExist(MenuAhkPath)\n\t\t\t\tcontinue\n\t\t\tExtName      := ExtId\n\t\t\tManifestPath := ExtDir . "\\manifest.toml"\n\t\t\tif FileExist(ManifestPath) {\n\t\t\t\ttry {\n\t\t\t\t\tMC := FileRead(ManifestPath, "UTF-8")\n\t\t\t\t\tif RegExMatch(MC, \'name\\s*=\\s*"([^"]+)"\', &NM)\n\t\t\t\t\t\tExtName := NM[1]\n\t\t\t\t}\n\t\t\t}\n\t\t\tConstructorOwner := MenuRenderer_ConstructObservedMenu, ObserverOwner := _SC_ObserveExtensionMenu\n\t\t\tif !(ConstructorOwner is Func) || !(ObserverOwner is Func)\n\t\t\t\t|| Object.Prototype.HasOwnProp.Call(ConstructorOwner, "Call")\n\t\t\t\t|| Object.Prototype.HasOwnProp.Call(ObserverOwner, "Call")\n\t\t\t\treturn []\n\t\t\tExtMenu := ConstructorOwner.Call("shortcut_extension_construction_ahk", ExtId, ExtName, ObserverOwner, OwnedMenus)\n\t\t\tif !(ExtMenu is Menu)\n\t\t\t\treturn []\n\t\t\tRows.Push(Map("label", ExtName, "submenu", ExtMenu))\n\t\t}\n\t\tCompleted := true\n\t} finally {\n\t\tif !Completed\n\t\t\t_SC_ExtensionDisposeOwnedMenus(OwnedMenus)\n\t}\n\treturn Rows\n}\n',
	_SC_ObserveExtensionMenu:
		'_SC_ObserveExtensionMenu(ExtId, ExtName, ExtMenu) {\n\tMarkerOutcome := "populated"\n\tBuilderFn := "BuildExtMenu_" . StrReplace(ExtId, "-", "_")\n\tif IsSet(%BuilderFn%) and HasMethod(%BuilderFn%) {\n\t\tBuildFailed := false\n\t\ttry {\n\t\t\t%BuilderFn%(ExtMenu, ExtName)\n\t\t} catch as Err {\n\t\t\t; A broken bundled extension is user-actionable, so fail LOUD:\n\t\t\t; ERROR (not a Warn the user never reads) plus a visible disabled\n\t\t\t; row in the submenu so a crashed builder is not indistinguishable\n\t\t\t; from an absent one.\n\t\t\tLoggerError("Extensions", "BuildExtMenu for \'{1}\' threw: {2}.", ExtId, Err.Message)\n\t\t\tBuildFailed := true\n\t\t}\n\t\t; Even a builder that returns without throwing may have populated\n\t\t; nothing (bad TOML, missing global) \u2014 an empty submenu is just as\n\t\t; opaque, so surface the same marker.\n\t\tif (BuildFailed or _ExtMenuItemCount(ExtMenu) == 0) {\n\t\t\tif !BuildFailed\n\t\t\t\tLoggerError("Extensions", "BuildExtMenu for \'{1}\' added no items \u2014 extension menu is empty.", ExtId)\n\t\t\t; A label and nothing else: the renderer draws it inert and greyed,\n\t\t\t; which is exactly what a marker is.\n\t\t\tMarkerOutcome := BuildFailed ? "failed" : "empty"\n\t\t}\n\t} else {\n\t\tLoggerWarn("Extensions", "No BuildExtMenu_{1} function found \u2014 menu.ahk not loaded?", StrReplace(ExtId, "-", "_"))\n\t\tMarkerOutcome := "missing"\n\t}\n\treturn MarkerOutcome\n}\n'
};

/** Uses the existing native masking owner, without extending its grammar. */
function shortcutReaderOwners(source) {
	if (typeof source !== 'string' || source === '') return null;
	const fs = require('node:fs'),
		path = require('node:path');
	const raw = fs.readFileSync(path.join(__dirname, '../test/test-ahk-loop-capture.cjs'), 'utf8');
	const begin = raw.indexOf('function codeLines(src) {'),
		end = raw.indexOf('/**', begin);
	if (begin < 0 || end <= begin) return null;
	const code = require('node:vm').runInNewContext(raw.slice(begin, end) + '\ncodeLines')(source);
	const starts = [0];
	for (let i = 0; i < source.length; i++) if (source[i] === '\n') starts.push(i + 1);
	let line = 0;
	const tokens = require('./script-source.cjs')
		.scriptTokens(source, '.ahk')
		.filter((token) => {
			while (line + 1 < starts.length && starts[line + 1] <= token.start) line++;
			if (token.kind === 'string')
				return source.slice(token.start, token.end) === JSON.stringify(token.value);
			const column = token.start - starts[line];
			return code[line]?.slice(column, column + token.value.length) === token.value;
		});
	const depths = [],
		closes = new Map(),
		stack = [];
	for (let i = 0; i < tokens.length; i++) {
		depths[i] = stack.length;
		if (tokens[i].kind === 'symbol' && tokens[i].value === '{') stack.push(i);
		else if (tokens[i].kind === 'symbol' && tokens[i].value === '}') {
			if (!stack.length) return null;
			closes.set(stack.pop(), i);
		}
	}
	if (stack.length) return null;
	const owners = new Map();
	for (let i = 0; i < tokens.length; i++) {
		const token = tokens[i];
		if (
			depths[i] ||
			token.kind !== 'identifier' ||
			tokens[i + 1]?.value !== '(' ||
			source.slice(source.lastIndexOf('\n', token.start - 1) + 1, token.start).trim() !== ''
		)
			continue;
		let at = i + 2,
			args = 1;
		while (at < tokens.length && args) {
			if (tokens[at].value === '(') args++;
			if (tokens[at].value === ')') args--;
			at++;
		}
		if (args || tokens[at]?.value !== '{' || !closes.has(at)) continue;
		const owned = source.slice(token.start, tokens[closes.get(at)].end) + '\n';
		const entries = owners.get(token.value) || [];
		entries.push(owned);
		owners.set(token.value, entries);
	}
	return owners;
}

function shortcutReaderDataRecord(value) {
	if (
		!value ||
		typeof value !== 'object' ||
		Array.isArray(value) ||
		![Object.prototype, null].includes(Object.getPrototypeOf(value))
	)
		return false;
	return Reflect.ownKeys(value).every(
		(key) =>
			typeof key === 'string' && Object.hasOwn(Object.getOwnPropertyDescriptor(value, key), 'value')
	);
}
function shortcutReaderDataArray(value) {
	if (
		!Array.isArray(value) ||
		Object.getPrototypeOf(value) !== Array.prototype ||
		Object.keys(value).length !== value.length ||
		Reflect.ownKeys(value).length !== value.length + 1
	)
		return false;
	for (let i = 0; i < value.length; i++)
		if (
			!Object.hasOwn(value, i) ||
			!Object.hasOwn(Object.getOwnPropertyDescriptor(value, String(i)), 'value')
		)
			return false;
	return true;
}

/** Credits the declared frame only through the actual closed native consumer. */
function shortcutConstructionReaderEvidence(menu, windows, renderer) {
	try {
		if (
			!shortcutReaderDataRecord(menu) ||
			!Object.hasOwn(menu, 'shortcut_extension_construction_ahk')
		)
			return null;
		const recipe = menu.shortcut_extension_construction_ahk;
		if (
			!shortcutReaderDataRecord(recipe) ||
			!shortcutReaderDataArray(recipe.program) ||
			!shortcutReaderDataArray(recipe.append_outcomes)
		)
			return null;
		validateChildTemplates({ shortcut_extension_construction_ahk: recipe });
		if (
			!Object.hasOwn(menu, recipe.result_frame) ||
			!shortcutReaderDataArray(menu[recipe.result_frame])
		)
			return null;
		const native = shortcutReaderOwners(renderer),
			producer = shortcutReaderOwners(windows);
		if (!native || !producer) return null;
		const exact = (owners, contracts) =>
			Object.entries(contracts).every(
				([name, body]) => owners.get(name)?.length === 1 && owners.get(name)[0] === body
			);
		if (
			!exact(native, shortcutReaderRendererOwners) ||
			!exact(producer, shortcutReaderProducerOwners)
		)
			return null;
		return {
			sections: [recipe.result_frame],
			captionGetters: ['shortcut_extension_name'],
			presentWhen: recipe.append_outcomes.map((outcome) => 'shortcut_extension_builder_' + outcome)
		};
	} catch {
		return null;
	}
}
module.exports.shortcutConstructionReaderEvidence = shortcutConstructionReaderEvidence;
