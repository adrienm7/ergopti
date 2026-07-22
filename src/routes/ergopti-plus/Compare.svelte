<!-- src/routes/ergopti-plus/Compare.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Comparison vs Alternatives
DESCRIPTION:
An honest, non-disparaging comparison. Ergopti+ is built ON AutoHotkey and
Hammerspoon, so the point is not "they are bad" but "Ergopti+ bundles the
whole experience — free, local, unified across OSes — with no scripting."
==============================================================================
-->

<script>
	import { reveal } from './reveal.js';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';

	const cols = ['Ergopti+', 'Espanso', 'AutoHotkey', 'TextExpander', 'Autocorr. native'];

	// status: 'yes' | 'no' | text nuance
	const rows = [
		{ label: 'Gratuit', cells: ['yes', 'yes', 'yes', 'no', 'yes'] },
		{ label: '100 % local, sans compte', cells: ['yes', 'yes', 'yes', 'cloud', 'yes'] },
		{ label: 'Windows · macOS · Linux', cells: ['3 OS', '3 OS', 'Windows', '2 OS', 'variable'] },
		{ label: 'Hotstrings + autocorrection', cells: ['yes', 'yes', 'yes', 'yes', 'basique'] },
		{ label: 'IA locale intégrée', cells: ['yes', 'no', 'no', 'no', 'no'] },
		{ label: 'Tap-holds + gestes trackpad', cells: ['yes', 'no', 'script', 'no', 'no'] },
		{ label: 'Métriques de frappe', cells: ['yes', 'no', 'no', 'no', 'no'] },
		{ label: 'Config sans écrire de code', cells: ['yes', 'YAML', 'script', 'yes', 'yes'] }
	];

	/**
	 * Map a status to its display cell.
	 * @param {string} s
	 * @returns {{cls: string, text: string}}
	 */
	function cell(s) {
		if (s === 'yes') return { cls: 'ok', text: '✓' };
		if (s === 'no') return { cls: 'off', text: '—' };
		return { cls: 'note', text: s };
	}
</script>

<section class="compare" id="ep-comparatif" style="--section-accent: #f59e0b;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Comparatif</p>
			<h2>Tout au même endroit, gratuitement.</h2>
			<p class="lead">
				Les outils ci-dessous sont excellents — <ErgoptiPlus></ErgoptiPlus> s’appuie d’ailleurs sur AutoHotkey
				et Hammerspoon. La différence : une <strong>suite complète, locale et unifiée</strong> sur les
				trois OS, sans rien scripter.
			</p>
		</header>

		<div class="table-wrap" use:reveal>
			<table class="cmp">
				<thead>
					<tr>
						<th class="feat-col">Fonctionnalité</th>
						{#each cols as c, i}
							<th class:hero-col={i === 0}>{c}</th>
						{/each}
					</tr>
				</thead>
				<tbody>
					{#each rows as row, ri}
						<tr style="--row: {ri};">
							<td class="feat-col">{row.label}</td>
							{#each row.cells as status, ci}
								{@const c = cell(status)}
								<td class="cell {c.cls}" class:hero-col={ci === 0}>{c.text}</td>
							{/each}
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
		<p class="cmp-note" use:reveal>
			Comparatif indicatif des offres par défaut, dressé de bonne foi — chaque outil a ses forces.
		</p>
	</div>
</section>

<style>
	.table-wrap {
		background: linear-gradient(180deg, rgba(255, 255, 255, 0.05), rgba(255, 255, 255, 0.02));
		border: 1px solid var(--border);
		border-radius: var(--radius-lg);
		overflow-x: auto;
	}

	.cmp {
		border-collapse: collapse;
		min-width: 680px;
		width: 100%;
	}

	.cmp th,
	.cmp td {
		border-bottom: 1px solid var(--border);
		padding: 12px 14px;
		text-align: center;
	}

	.cmp tbody tr:last-child td {
		border-bottom: 0;
	}

	.cmp thead th {
		font-size: 0.9rem;
		font-weight: 700;
	}

	.feat-col {
		font-size: 0.9rem;
		text-align: left !important;
	}

	td.feat-col {
		color: var(--ink-soft);
	}

	/* The Ergopti+ column is highlighted — it is the reference. */
	.hero-col {
		background: rgba(245, 158, 11, 0.08);
	}

	thead .hero-col {
		color: #ffcf7a;
	}

	.cell.ok {
		color: #4ade80;
		font-weight: 700;
	}

	.cell.off {
		color: rgba(255, 255, 255, 0.25);
	}

	.cell.note {
		color: var(--ink-soft);
		font-size: 0.8rem;
	}

	@media (prefers-reduced-motion: no-preference) {
		.table-wrap.is-visible .cell {
			animation: cmp-cell-in 0.5s var(--ease-out) both;
			animation-delay: calc(var(--row, 0) * 50ms + 120ms);
		}
	}

	@keyframes cmp-cell-in {
		from {
			opacity: 0;
			transform: scale(0.6);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}

	.cmp-note {
		color: var(--ink-faint);
		font-size: 0.78rem;
		margin: 14px auto 0;
		max-width: 560px;
		text-align: center;
	}
</style>
