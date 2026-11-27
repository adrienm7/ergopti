// packages/hotstrings-web/src/placeholders.ts

/**
 * Placeholder expansion of a hotstring output.
 *
 * Supported: `{cursor}` (where the caret goes; removed from the text),
 * `{selection}`, `{date}` (ISO yyyy-mm-dd), `{date:FORMAT}` (tokens YYYY, MM,
 * DD), `{value:NAME}` (from `values`), and the escapes `{{` and `}}`. Any other
 * brace text, and a `{value:NAME}` whose name is not given, stays verbatim.
 * Markup such as Typst `#mention("id")[Name]` is plain text here.
 */

/** What the placeholders read. */
export interface PlaceholderContext {
	/** The date `{date}` reads; the current date when absent. */
	date?: Date;
	/** The text `{selection}` stands for; empty when absent. */
	selection?: string;
	/** The values `{value:NAME}` reads. */
	values?: Record<string, string>;
}

/** An expanded output. */
export interface ExpandedOutput {
	/** The text to insert. */
	text: string;
	/** UTF-16 offset of the first `{cursor}` in `text`, or null when there is none. */
	cursor: number | null;
}

function pad(value: number, width: number): string {
	return String(value).padStart(width, '0');
}

/**
 * Formats a date with the tokens YYYY, MM and DD; every other character is kept.
 * @param date The date, read in local time.
 * @param format The format, e.g. `DD/MM/YYYY`.
 * @returns The formatted date.
 */
export function formatDate(date: Date, format: string): string {
	return format.replace(/YYYY|MM|DD/g, (token) => {
		if (token === 'YYYY') return pad(date.getFullYear(), 4);
		if (token === 'MM') return pad(date.getMonth() + 1, 2);
		return pad(date.getDate(), 2);
	});
}

/**
 * Resolves one placeholder body (the text between the braces).
 * @returns The replacement, the cursor marker, or null to keep it verbatim.
 */
function resolve(body: string, ctx: PlaceholderContext): string | { cursor: true } | null {
	if (body === 'cursor') return { cursor: true };
	if (body === 'selection') return ctx.selection ?? '';
	if (body === 'date') return formatDate(ctx.date ?? new Date(), 'YYYY-MM-DD');
	if (body.startsWith('date:')) return formatDate(ctx.date ?? new Date(), body.slice(5));
	if (body.startsWith('value:')) {
		const name = body.slice(6);
		const values = ctx.values ?? {};
		return Object.hasOwn(values, name) ? values[name] : null;
	}
	return null;
}

/**
 * Expands the placeholders of an output.
 * @param output The hotstring output.
 * @param ctx The values the placeholders read.
 * @returns The text and the cursor offset.
 */
export function expandOutput(output: string, ctx: PlaceholderContext = {}): ExpandedOutput {
	let text = '';
	let cursor: number | null = null;
	let i = 0;
	while (i < output.length) {
		const ch = output[i];
		const next = output[i + 1];
		if ((ch === '{' && next === '{') || (ch === '}' && next === '}')) {
			text += ch;
			i += 2;
			continue;
		}
		if (ch === '{') {
			const end = output.indexOf('}', i + 1);
			const body = end < 0 ? '' : output.slice(i + 1, end);
			const value = end < 0 || body.includes('{') ? null : resolve(body, ctx);
			if (value !== null) {
				if (typeof value === 'string') text += value;
				else if (cursor === null) cursor = text.length;
				i = end + 1;
				continue;
			}
		}
		text += ch;
		i += 1;
	}
	return { text, cursor };
}
