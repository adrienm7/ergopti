<!-- packages/hotstrings-web/src/HotstringEditor.svelte -->

<!--
	A list and a form to add, edit and delete hotstrings, and to import and
	export TOML v2, ported in spirit from Ergopti's desktop editor
	(static/ergopti_plus/_shared/ui/hotstring_editor/). Every rule lives in
	editor_model.ts; this file only renders it. Texts come from `labels`
	(English defaults; callers translate).
-->

<script lang="ts">
	import {
		DEFAULT_LABELS,
		emptyDraft,
		errorLabel,
		exportToml,
		importToml,
		parseTags,
		problemLabel,
		removeAt,
		saveDraft,
		validateDraft,
		type DraftProblem,
		type EditorLabels
	} from './editor_model.js';
	import type { HotstringFileError } from './toml.js';
	import type { Hotstring } from './types.js';

	interface Props {
		hotstrings?: Hotstring[];
		labels?: Partial<EditorLabels>;
		onchange?: (list: Hotstring[]) => void;
	}

	let { hotstrings = $bindable([]), labels = {}, onchange }: Props = $props();

	const text = $derived({ ...DEFAULT_LABELS, ...labels });
	const uid = Math.random().toString(36).slice(2, 8);
	const id = (name: string) => `hse-${uid}-${name}`;

	let draft: Hotstring = $state(emptyDraft());
	let formOpen = $state(false);
	let editing: number | null = $state(null);
	let tagText = $state('');
	let problems: DraftProblem[] = $state([]);
	let importErrors: HotstringFileError[] = $state([]);
	let replaceOnImport = $state(false);

	const exportHref = $derived(
		`data:application/toml;charset=utf-8,${encodeURIComponent(exportToml(hotstrings))}`
	);

	function publish(list: Hotstring[]) {
		hotstrings = list;
		onchange?.(list);
	}

	function open(index: number | null) {
		editing = index;
		draft = index === null ? emptyDraft() : { ...hotstrings[index] };
		tagText = (draft.tags ?? []).join(', ');
		problems = [];
		formOpen = true;
	}

	function close() {
		formOpen = false;
		editing = null;
		problems = [];
	}

	function save(event: SubmitEvent) {
		event.preventDefault();
		const candidate = { ...draft, tags: parseTags(tagText) };
		problems = validateDraft(candidate, hotstrings, editing);
		if (problems.length > 0) return;
		publish(saveDraft(hotstrings, candidate, editing));
		close();
	}

	async function onImport(event: Event) {
		const input = event.currentTarget as HTMLInputElement;
		const file = (input.files as FileList)[0];
		const result = importToml(hotstrings, await file.text(), replaceOnImport);
		importErrors = result.errors;
		publish(result.list);
		input.value = '';
	}
</script>

<section class="hotstring-editor" aria-labelledby={id('title')}>
	<h2 id={id('title')}>{text.title}</h2>

	{#if hotstrings.length === 0}
		<p>{text.empty}</p>
	{:else}
		<ul class="hotstring-list">
			{#each hotstrings as hotstring, index (index)}
				<li>
					<code>{hotstring.trigger}</code> → <span>{hotstring.output}</span>
					<small>{hotstring.description}</small>
					<button type="button" onclick={() => open(index)}>
						{text.edit}<span class="visually-hidden"> {hotstring.trigger}</span>
					</button>
					<button type="button" onclick={() => publish(removeAt(hotstrings, index))}>
						{text.remove}<span class="visually-hidden"> {hotstring.trigger}</span>
					</button>
				</li>
			{/each}
		</ul>
	{/if}

	<div class="toolbar">
		<button type="button" onclick={() => open(null)}>{text.add}</button>
		<label>
			{text.importToml}
			<input type="file" accept=".toml,text/plain" onchange={onImport} />
		</label>
		<label>
			<input type="checkbox" bind:checked={replaceOnImport} />
			{text.importReplace}
		</label>
		<a href={exportHref} download="hotstrings.toml">{text.exportToml}</a>
	</div>

	{#if importErrors.length > 0}
		<ul role="alert" class="errors">
			{#each importErrors as error, index (index)}
				<li>{errorLabel(error, text)}</li>
			{/each}
		</ul>
	{/if}

	{#if formOpen}
		<form onsubmit={save} aria-labelledby={id('title')}>
			<label for={id('trigger')}>{text.trigger}</label>
			<input id={id('trigger')} bind:value={draft.trigger} aria-required="true" />

			<label for={id('output')}>{text.output}</label>
			<textarea id={id('output')} bind:value={draft.output}></textarea>

			<label for={id('expand')}>{text.expand}</label>
			<select id={id('expand')} bind:value={draft.expand}>
				<option value="terminator">{text.expandTerminator}</option>
				<option value="immediate">{text.expandImmediate}</option>
				<option value="enter">{text.expandEnter}</option>
				<option value="tab">{text.expandTab}</option>
				<option value="key">{text.expandKey}</option>
			</select>

			{#if draft.expand === 'key'}
				<label for={id('key')}>{text.key}</label>
				<input id={id('key')} bind:value={draft.key} />
			{/if}

			<label for={id('terminator')}>{text.terminator}</label>
			<select id={id('terminator')} bind:value={draft.terminator}>
				<option value="echo">{text.terminatorEcho}</option>
				<option value="consume">{text.terminatorConsume}</option>
			</select>

			<label
				><input type="checkbox" bind:checked={draft.caseSensitive} /> {text.caseSensitive}</label
			>
			{#if !draft.caseSensitive}
				<label>
					<input
						type="checkbox"
						checked={draft.conformCase !== false}
						onchange={(event) => (draft.conformCase = event.currentTarget.checked)}
					/>
					{text.conformCase}
				</label>
			{/if}
			<label><input type="checkbox" bind:checked={draft.wordStart} /> {text.wordStart}</label>

			<label for={id('description')}>{text.description}</label>
			<input id={id('description')} bind:value={draft.description} />

			<label for={id('tags')}>{text.tags}</label>
			<input id={id('tags')} bind:value={tagText} />

			{#if problems.length > 0}
				<ul role="alert" class="errors">
					{#each problems as problem (problem)}
						<li>{problemLabel(problem, text)}</li>
					{/each}
				</ul>
			{/if}

			<button type="submit">{text.save}</button>
			<button type="button" onclick={close}>{text.cancel}</button>
		</form>
	{/if}
</section>

<style>
	.hotstring-editor form {
		display: grid;
		gap: 0.25rem 0.75rem;
		grid-template-columns: max-content 1fr;
	}

	.hotstring-editor form > label:has(input[type='checkbox']),
	.hotstring-editor form > ul,
	.hotstring-editor form > button {
		grid-column: 1 / -1;
	}

	.hotstring-editor .errors {
		font-weight: bold;
	}

	.visually-hidden {
		clip-path: inset(50%);
		height: 1px;
		overflow: hidden;
		position: absolute;
		white-space: nowrap;
		width: 1px;
	}
</style>
