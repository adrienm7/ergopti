// packages/hotstrings-web/tests/HotstringEditor.test.ts
// @vitest-environment jsdom

import { flushSync, mount, unmount } from 'svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import HotstringEditor from '../src/HotstringEditor.svelte';
import { emptyDraft } from '../src/editor_model.js';
import { serializeHotstrings } from '../src/toml.js';
import type { Hotstring } from '../src/types.js';

const btw: Hotstring = { ...emptyDraft(), trigger: 'btw', output: 'by the way', description: 'common' };
let app: Record<string, unknown> | null = null;

afterEach(() => {
	if (app) unmount(app);
	app = null;
	document.body.innerHTML = '';
});

function render(props: Record<string, unknown> = {}) {
	const target = document.createElement('div');
	document.body.append(target);
	app = mount(HotstringEditor, { target, props });
	return target;
}

function byLabel(root: HTMLElement, text: string): HTMLInputElement {
	const label = Array.from(root.querySelectorAll('label')).find((l) => l.textContent?.trim().startsWith(text));
	if (!label) throw new Error(`no label ${text}`);
	const control = label.htmlFor ? root.querySelector(`#${label.htmlFor}`) : label.querySelector('input');
	return control as HTMLInputElement;
}

function button(root: HTMLElement, text: string): HTMLButtonElement {
	return Array.from(root.querySelectorAll('button')).find((b) => b.textContent?.trim().startsWith(text)) as HTMLButtonElement;
}

function type(control: HTMLInputElement, value: string) {
	control.value = value;
	control.dispatchEvent(new Event('input', { bubbles: true }));
	control.dispatchEvent(new Event('change', { bubbles: true }));
	flushSync();
}

function tick(control: HTMLInputElement, checked: boolean) {
	control.checked = checked;
	control.dispatchEvent(new Event('change', { bubbles: true }));
	flushSync();
}

describe('HotstringEditor', () => {
	it('shows the empty state with English defaults and translated labels', () => {
		expect(render().textContent).toContain('No hotstring yet.');
		unmount(app!);
		app = null;
		expect(render({ labels: { empty: 'Aucun.' } }).textContent).toContain('Aucun.');
	});

	it('adds a hotstring through the labelled form', () => {
		const onchange = vi.fn();
		const root = render({ onchange });
		button(root, 'New hotstring').click();
		flushSync();
		button(root, 'Save').click();
		flushSync();
		expect(root.querySelector('[role=alert]')?.textContent).toContain('The trigger is empty.');
		type(byLabel(root, 'Trigger'), 'sig');
		type(byLabel(root, 'Output'), 'Regards');
		const expand = byLabel(root, 'Expands') as unknown as HTMLSelectElement;
		expand.value = 'key';
		expand.dispatchEvent(new Event('change', { bubbles: true }));
		flushSync();
		button(root, 'Save').click();
		flushSync();
		expect(root.querySelector('[role=alert]')?.textContent).toContain('Choose the key.');
		type(byLabel(root, 'Key'), 'F2');
		tick(byLabel(root, 'Output follows'), false);
		tick(byLabel(root, 'Only at the start'), false);
		type(byLabel(root, 'Tags'), 'mail, work');
		type(byLabel(root, 'Description'), 'Mail signature');
		const terminator = byLabel(root, 'Terminator') as unknown as HTMLSelectElement;
		terminator.value = 'consume';
		terminator.dispatchEvent(new Event('change', { bubbles: true }));
		flushSync();
		button(root, 'Save').click();
		flushSync();
		expect(onchange).toHaveBeenLastCalledWith([
			{
				trigger: 'sig',
				output: 'Regards',
				expand: 'key',
				key: 'F2',
				terminator: 'consume',
				caseSensitive: false,
				conformCase: false,
				wordStart: false,
				description: 'Mail signature',
				tags: ['mail', 'work']
			}
		]);
		expect(root.querySelector('form')).toBeNull();
		expect(root.querySelector('code')?.textContent).toBe('sig');
	});

	it('edits, cancels and deletes an existing hotstring, and links the export', () => {
		const onchange = vi.fn();
		const root = render({ hotstrings: [btw], onchange });
		expect(root.textContent).toContain('common');
		const link = root.querySelector('a[download]') as HTMLAnchorElement;
		expect(decodeURIComponent(link.href.split(',')[1])).toBe(serializeHotstrings([btw]));
		button(root, 'Edit').click();
		flushSync();
		expect(byLabel(root, 'Trigger').value).toBe('btw');
		tick(byLabel(root, 'Case sensitive'), true);
		expect(root.textContent).not.toContain('Output follows');
		button(root, 'Cancel').click();
		flushSync();
		expect(root.querySelector('form')).toBeNull();
		button(root, 'Edit').click();
		flushSync();
		type(byLabel(root, 'Output'), 'BY THE WAY');
		button(root, 'Save').click();
		flushSync();
		expect(onchange).toHaveBeenLastCalledWith([{ ...btw, output: 'BY THE WAY' }]);
		button(root, 'Delete').click();
		flushSync();
		expect(onchange).toHaveBeenLastCalledWith([]);
		expect(root.textContent).toContain('No hotstring yet.');
	});

	it('imports a file, appending or replacing, and lists its errors', async () => {
		const root = render({ hotstrings: [btw] });
		const input = root.querySelector('input[type=file]') as HTMLInputElement;
		const load = async (text: string) => {
			const file = new File([text], 'h.toml');
			// jsdom's File has no text(); every browser has it.
			Object.defineProperty(file, 'text', { value: async () => text });
			Object.defineProperty(input, 'files', { value: [file], configurable: true });
			input.dispatchEvent(new Event('change', { bubbles: true }));
			await new Promise((resolve) => setTimeout(resolve, 0));
			flushSync();
		};
		await load(serializeHotstrings([{ ...btw, trigger: 'omw' }]) + 'bad = ?\n');
		expect(Array.from(root.querySelectorAll('code')).map((c) => c.textContent)).toEqual(['btw', 'omw']);
		expect(root.querySelector('[role=alert]')?.textContent).toContain('Line');
		tick(byLabel(root, 'Replace the list'), true);
		await load(serializeHotstrings([{ ...btw, trigger: 'new' }]));
		expect(Array.from(root.querySelectorAll('code')).map((c) => c.textContent)).toEqual(['new']);
		expect(root.querySelector('[role=alert]')).toBeNull();
	});

	it('renders a label a caller left undefined as empty text', () => {
		const blank = { importToml: undefined, importReplace: undefined, caseSensitive: undefined, conformCase: undefined, wordStart: undefined };
		const root = render({ labels: blank });
		button(root, 'New hotstring').click();
		flushSync();
		expect(root.querySelectorAll('input[type=checkbox]')).toHaveLength(4);
	});

	it('works without an onchange callback and without descriptions', () => {
		const root = render({ hotstrings: [{ ...emptyDraft(), trigger: 'omw', output: 'on my way' }] });
		expect(root.querySelector('small')?.textContent).toBe('');
		button(root, 'Delete').click();
		flushSync();
		expect(root.textContent).toContain('No hotstring yet.');
	});
});
