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
		if (row.type !== 'command' && row.type !== 'group')
			throw new Error(
				`${where}: disabled_reason_key is read on command rows only, or identified labelled groups`
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

function validateChildTemplates(menu, captionFormat) {
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
