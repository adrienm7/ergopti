<!-- src/lib/components/A11ySettings.svelte -->

<!--
==============================================================================
MODULE: Accessibility Settings
DESCRIPTION:
The header button and dialog where a visitor sets how the site looks to them:
less motion, a hyperlegible or a dyslexia font, a larger text, wider text
spacing, shorter lines, text aligned to the start, high contrast and colours
that colour-blind readers tell apart. The choices are owned by static/ergopti_plus/_shared/ui/a11y_prefs.js
(loaded by app.html before the page), which stores them per visitor and carries
them into the Ergopti Studio frames; this component only edits them. A browser
that refuses storage still gets the look for the current page, and is told so.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import { resolve } from '$app/paths';

	const FONTS = [
		['default', 'Police du site'],
		['hyperlegible', 'Atkinson Hyperlegible (très lisible)'],
		['dyslexic', 'OpenDyslexic (dyslexie)']
	];

	const TEXT_SIZES = [
		['100', '100 %'],
		['125', '125 %'],
		['150', '150 %'],
		['200', '200 %']
	];

	let dialog = $state();
	let prefs = $state({});
	let storageRefused = $state(false);

	onMount(() => {
		prefs = window.ErgoptiA11yPrefs.read();
	});

	/** Apply and remember one changed preference. */
	function set(name, value) {
		prefs = { ...prefs, [name]: value };
		storageRefused = !window.ErgoptiA11yPrefs.save(prefs);
	}

	/** A checkbox maps to the preference's second value, unchecked to its default. */
	function toggle(name, on) {
		const values = window.ErgoptiA11yPrefs.PREFERENCES[name].values;
		set(name, on ? values[1] : values[0]);
	}

	function reset() {
		prefs = {};
		storageRefused = !window.ErgoptiA11yPrefs.save(prefs);
	}

	function open() {
		prefs = window.ErgoptiA11yPrefs.read();
		dialog.showModal();
	}

	/** A click on the backdrop (the dialog element itself) closes it. */
	function closeOnBackdrop(event) {
		if (event.target === dialog) dialog.close();
	}
</script>

<button
	type="button"
	class="a11y-button"
	id="a11y-settings-button"
	aria-haspopup="dialog"
	aria-label="Réglages d’accessibilité"
	title="Réglages d’accessibilité"
	onclick={open}
>
	<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true" focusable="false">
		<circle cx="12" cy="12" r="11" fill="none" stroke="currentColor" stroke-width="1.8" />
		<circle cx="12" cy="6.6" r="1.7" fill="currentColor" />
		<path
			d="M6.5 9.2 12 10.4l5.5-1.2M12 10.4v4.2m0 0-2.6 4.6m2.6-4.6 2.6 4.6"
			fill="none"
			stroke="currentColor"
			stroke-linecap="round"
			stroke-linejoin="round"
			stroke-width="1.8"
		/>
	</svg>
</button>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions -->
<dialog
	bind:this={dialog}
	class="a11y-dialog"
	id="a11y-settings"
	aria-labelledby="a11y-settings-title"
	onclick={closeOnBackdrop}
>
	<form method="dialog">
		<h2 id="a11y-settings-title">Réglages d’accessibilité</h2>
		<p class="a11y-intro">
			Ces réglages s’appliquent à tout le site et à Ergopti Studio, et sont retenus par ce
			navigateur.
		</p>

		<label class="a11y-row">
			<input
				type="checkbox"
				id="a11y-motion"
				checked={prefs.motion === 'reduce'}
				onchange={(event) => toggle('motion', event.currentTarget.checked)}
			/>
			Réduire les animations et les défilements
		</label>

		<label class="a11y-row a11y-select">
			Police
			<select
				id="a11y-font"
				value={prefs.font || 'default'}
				onchange={(event) => set('font', event.currentTarget.value)}
			>
				{#each FONTS as [value, label] (value)}
					<option {value}>{label}</option>
				{/each}
			</select>
		</label>

		<label class="a11y-row a11y-select">
			Taille du texte
			<select
				id="a11y-text"
				value={prefs.text || '100'}
				onchange={(event) => set('text', event.currentTarget.value)}
			>
				{#each TEXT_SIZES as [value, label] (value)}
					<option {value}>{label}</option>
				{/each}
			</select>
		</label>

		<label class="a11y-row">
			<input
				type="checkbox"
				id="a11y-spacing"
				checked={prefs.spacing === 'wide'}
				onchange={(event) => toggle('spacing', event.currentTarget.checked)}
			/>
			Espacer les lettres, les mots et les lignes
		</label>

		<label class="a11y-row">
			<input
				type="checkbox"
				id="a11y-measure"
				checked={prefs.measure === 'short'}
				onchange={(event) => toggle('measure', event.currentTarget.checked)}
			/>
			Raccourcir les lignes de texte
		</label>

		<label class="a11y-row">
			<input
				type="checkbox"
				id="a11y-align"
				checked={prefs.align === 'start'}
				onchange={(event) => toggle('align', event.currentTarget.checked)}
			/>
			Aligner tout le texte à gauche
		</label>

		<label class="a11y-row">
			<input
				type="checkbox"
				id="a11y-contrast"
				checked={prefs.contrast === 'high'}
				onchange={(event) => toggle('contrast', event.currentTarget.checked)}
			/>
			Contraste élevé
		</label>

		<label class="a11y-row">
			<input
				type="checkbox"
				id="a11y-colors"
				checked={prefs.colors === 'cvd'}
				onchange={(event) => toggle('colors', event.currentTarget.checked)}
			/>
			Couleurs adaptées au daltonisme
		</label>

		<p class="a11y-status" role="status">
			{#if storageRefused}
				Ce navigateur refuse l’enregistrement : les réglages valent pour cette page seulement.
			{/if}
		</p>

		<div class="a11y-actions">
			<button type="button" onclick={reset}>Réinitialiser</button>
			<button type="submit" class="a11y-close">Fermer</button>
		</div>
		<p class="a11y-statement">
			<a href={resolve('/accessibilite')} onclick={() => dialog.close()}
				>Déclaration d’accessibilité</a
			>
		</p>
	</form>
</dialog>

<style>
	.a11y-button {
		align-items: center;
		background: transparent;
		border: 1px solid rgba(255, 255, 255, 0.35);
		border-radius: 8px;
		color: white;
		cursor: pointer;
		display: inline-flex;
		flex: none;
		height: 40px;
		justify-content: center;
		margin-left: auto;
		margin-right: var(--marge-bords-menu, 15px);
		padding: 0;
		width: 40px;
	}

	.a11y-button:hover {
		background: rgba(255, 255, 255, 0.12);
	}

	.a11y-dialog {
		background: #0b1726;
		border: 1px solid rgba(255, 255, 255, 0.4);
		border-radius: 12px;
		color: white;
		max-height: calc(100dvh - 32px);
		max-width: min(30rem, calc(100vw - 32px));
		overflow: auto;
		padding: 1.25rem 1.5rem;
	}

	.a11y-dialog::backdrop {
		background: rgba(0, 0, 0, 0.6);
	}

	.a11y-dialog h2 {
		font-size: 1.3rem;
		margin: 0 0 0.5rem;
	}

	.a11y-intro {
		color: #d6e4f0;
		margin: 0 0 1rem;
	}

	.a11y-row {
		align-items: center;
		cursor: pointer;
		display: flex;
		gap: 0.75rem;
		min-height: 44px;
	}

	.a11y-row input[type='checkbox'] {
		flex: none;
		height: 22px;
		width: 22px;
	}

	.a11y-select {
		justify-content: space-between;
	}

	.a11y-select select {
		background: #000;
		border: 1px solid rgba(255, 255, 255, 0.6);
		border-radius: 6px;
		color: white;
		min-height: 32px;
		padding: 0 0.5rem;
	}

	.a11y-status {
		color: #ffd60a;
		margin: 0.5rem 0;
		min-height: 1em;
	}

	.a11y-actions {
		display: flex;
		gap: 0.75rem;
		justify-content: flex-end;
	}

	.a11y-actions button {
		background: transparent;
		border: 1px solid rgba(255, 255, 255, 0.6);
		border-radius: 8px;
		color: white;
		cursor: pointer;
		font: inherit;
		min-height: 40px;
		padding: 0 1rem;
	}

	.a11y-actions .a11y-close {
		background: #0062cc;
		border-color: #0062cc;
	}

	.a11y-statement {
		margin: 1rem 0 0;
		text-align: right;
	}

	.a11y-statement a {
		color: #8fd0ff;
	}
</style>
