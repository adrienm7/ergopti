<!-- src/routes/ergopti-plus/TextReplacements.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — ★ Text Replacements
DESCRIPTION:
Every text replacement of the magic key catalogue, listed by section, with a
search across all of them. The list comes from the TOML files the drivers
load (site-data.server.js), so it can never drift from what users install.

FEATURES & RATIONALE:
1. Native Disclosure: each section is a details element, so the long lists
   stay folded, open from the keyboard and announce their state with no
   script of their own.
2. Real Tables: a trigger and its output are a row of a captioned table with
   column headers, which a screen reader reads cell by cell.
3. One Search: the field filters every section at once, opens those that
   match and says in a live output how many replacements remain.
4. The ★ Stays: the catalogue writes the magic key as ★; the drivers swap in
   the configured character at run time, the site shows the data as is.
==============================================================================
-->

<script>
	import { reveal } from './reveal.js';
	import { i18n, localized, t } from './i18n.svelte.js';

	/**
	 * @type {{
	 *   sections: Array<{id: string, label: string, labelEn: string, lang: string|null, entries: Array<[string, string]>}>
	 * }}
	 */
	let { sections } = $props();

	let query = $state('');
	// Which sections are unfolded, by position; the search opens the matches.
	let opened = $state([]);

	let needle = $derived(query.trim().toLocaleLowerCase());
	let filtered = $derived(
		sections.map((section) => ({
			...section,
			shown: needle
				? section.entries.filter(([trigger, output]) =>
						(trigger + '\n' + output).toLocaleLowerCase().includes(needle)
					)
				: section.entries
		}))
	);
	let total = $derived(sections.reduce((sum, section) => sum + section.entries.length, 0));
	let shownTotal = $derived(filtered.reduce((sum, section) => sum + section.shown.length, 0));

	/** Unfold every section holding a match, so a search result is never hidden. */
	function onSearch() {
		if (!needle) return;
		opened = filtered.map((section, i) => opened[i] || section.shown.length > 0);
	}

	/**
	 * Format a count with the thousands separator of the page's language.
	 * @param {number} n
	 * @returns {string}
	 */
	function fmt(n) {
		return n.toLocaleString(i18n.lang === 'en' ? 'en-GB' : 'fr-FR');
	}
</script>

<section class="replacements" id="ep-remplacements" style="--section-accent: #e53935;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">{t('Touche ★')}</p>
			<h2>{t('Tous les remplacements de texte de la touche ★')}</h2>
			<p class="lead">
				{t(
					'La liste complète, lue dans les fichiers que le driver charge. Tapez l’abréviation puis ★ : elle est remplacée par le texte de droite.'
				)}
			</p>
		</header>

		<search class="rep-search">
			<label for="rep-query">{t('Rechercher un remplacement')}</label>
			<input
				id="rep-query"
				type="search"
				autocomplete="off"
				spellcheck="false"
				bind:value={query}
				oninput={onSearch}
			/>
			<output for="rep-query" aria-live="polite">
				{needle
					? t('{shown} sur {total} remplacements', { shown: fmt(shownTotal), total: fmt(total) })
					: t('{total} remplacements', { total: fmt(total) })}
			</output>
		</search>

		{#each filtered as section, i (i)}
			<details
				class="rep-group"
				data-section={section.id}
				hidden={section.shown.length === 0}
				bind:open={opened[i]}
			>
				<summary>
					<strong class="rep-label">{localized(section.label, section.labelEn)}</strong>
					<data class="rep-count" value={section.shown.length}>{fmt(section.shown.length)}</data>
				</summary>
				<table class="rep-table" lang={section.lang}>
					<caption class="visually-hidden">{localized(section.label, section.labelEn)}</caption>
					<thead>
						<tr>
							<th scope="col" lang={i18n.lang}>{t('Abréviation')}</th>
							<th scope="col" lang={i18n.lang}>{t('Remplacement')}</th>
						</tr>
					</thead>
					<tbody>
						{#each section.shown as [trigger, output]}
							<tr>
								<td><code>{trigger}</code></td>
								<td>{output}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</details>
		{/each}
		{#if shownTotal === 0}
			<p class="rep-empty">{t('Aucun remplacement ne correspond à cette recherche.')}</p>
		{/if}
	</div>
</section>

<style>
	.rep-search {
		align-items: center;
		display: flex;
		flex-wrap: wrap;
		gap: 8px 14px;
		margin-bottom: 18px;
	}

	.rep-search label {
		color: var(--ink-soft);
		font-weight: 600;
	}

	.rep-search input {
		background: var(--surface-strong);
		border: 1px solid var(--border-strong);
		border-radius: 8px;
		color: var(--ink);
		flex: 1 1 220px;
		font: inherit;
		min-height: 44px;
		padding: 8px 12px;
	}

	.rep-search output {
		color: var(--ink-faint);
		font-size: 0.9rem;
	}

	.rep-group {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 12px;
		margin-bottom: 10px;
	}

	.rep-group summary {
		align-items: baseline;
		cursor: pointer;
		display: flex;
		gap: 12px;
		min-height: 44px;
		padding: 12px 16px;
	}

	.rep-label {
		color: var(--ink);
		flex: 1;
	}

	.rep-count {
		color: var(--ink-faint);
		font-variant-numeric: tabular-nums;
	}

	.rep-table {
		border-collapse: collapse;
		table-layout: fixed;
		width: 100%;
	}

	.rep-table th,
	.rep-table td {
		border-top: 1px solid var(--border);
		overflow-wrap: anywhere;
		padding: 6px 16px;
		text-align: start;
	}

	.rep-table th {
		color: var(--ink-soft);
		font-size: 0.85rem;
	}

	.rep-table td {
		color: var(--ink);
	}

	/* Leading and trailing spaces belong to some triggers and outputs. */
	.rep-table code,
	.rep-table td {
		white-space: pre-wrap;
	}

	.rep-table code {
		font-family: 'SF Mono', 'Cascadia Code', Menlo, Consolas, monospace;
		font-size: 0.9rem;
	}

	.rep-empty {
		color: var(--ink-soft);
	}
</style>
