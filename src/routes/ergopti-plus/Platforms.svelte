<!-- src/routes/ergopti-plus/Platforms.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Platforms & Download
DESCRIPTION:
The three-driver story with an HONEST feature matrix (verified against the
source tree), the Linux alpha disclaimer with a call for testers, and the
final download call-to-action.

FEATURES & RATIONALE:
1. Verified Matrix: every cell was checked against the driver sources —
   Windows and macOS are at effective parity (the page previously claimed
   Windows lacked the LLM bridge and metrics, which is false today).
2. Honest Alpha: the Linux driver is presented as what it is — complete on
   paper, never run on real hardware — which builds more trust than a fake
   checkmark ever could.
==============================================================================
-->

<script>
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import { ui } from './state.svelte.js';
	import { reveal } from './reveal.js';
	import { t } from './i18n.svelte.js';

	/** @type {{macosApps: Array<{id: string, name: string, description: string}>}} */
	let { macosApps } = $props();

	// Verified against the source tree — see the per-row nuance labels.
	// status: 'yes' | 'no' | text label rendered as-is.
	const matrix = [
		{ label: 'Hotstrings + autocorrection (2 994 livrés)', win: 'yes', mac: 'yes', linux: 'alpha' },
		{ label: 'Touche magique ★ (2 121 expansions)', win: 'yes', mac: 'yes', linux: 'alpha' },
		{ label: 'Hotstrings personnels + dynamiques', win: 'yes', mac: 'yes', linux: 'alpha' },
		{ label: 'Tap-holds (7 touches) + layer navigation', win: 'yes', mac: 'yes', linux: 'kanata' },
		{ label: 'Tooltips colorés en temps réel', win: 'yes', mac: 'yes', linux: 'X11' },
		{ label: 'IA locale via Ollama (110 modèles)', win: 'yes', mac: 'yes', linux: 'alpha' },
		{ label: 'IA distante (9 fournisseurs d’API)', win: 'yes', mac: 'yes', linux: 'no' },
		{ label: 'Backend MLX (Apple Silicon)', win: 'no', mac: 'yes', linux: 'no' },
		{ label: 'Gestes trackpad', win: '10 slots', mac: '36 + 3 axes', linux: 'no' },
		{ label: 'Métriques de frappe + tableaux de bord', win: 'yes', mac: 'yes', linux: 'alpha' },
		{ label: 'Widget WPM flottant', win: 'yes', mac: 'yes', linux: 'no' },
		{ label: 'Menu complet (335 réglages, 21 langues)', win: 'yes', mac: 'yes', linux: 'alpha' },
		{ label: 'Mises à jour automatiques', win: 'yes', mac: 'yes', linux: 'alpha' },
		{ label: 'Spotlight curseur (présentations)', win: 'yes', mac: 'yes', linux: 'no' }
	];

	/**
	 * Map a matrix status to its display cell.
	 * @param {string} status
	 * @returns {{cls: string, text: string}}
	 */
	function cell(status) {
		if (status === 'yes') return { cls: 'ok', text: '✓' };
		if (status === 'no') return { cls: 'off', text: '—' };
		if (status === 'alpha') return { cls: 'warn', text: 'α' };
		return { cls: 'note', text: status };
	}

	let urlWindows = $derived(ui.release?.url('ErgoptiPlus.exe') ?? '#');
	let urlMacos = $derived(ui.release?.url('ErgoptiPlus.app.zip') ?? '#');
	let urlKanata = $derived(ui.release?.url('kanata.kbd') ?? '#');
</script>

<section class="platforms" id="ep-telecharger" style="--section-accent: var(--accent-blue);">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Trois systèmes</p>
			<h2>Windows et macOS à parité. Linux en alpha.</h2>
			<p class="lead">
				Le même fichier de hotstrings, les mêmes raccourcis, le même tooltip, le même menu — sur
				AutoHotkey v2 (Windows) et Hammerspoon (macOS). Le driver Linux (kanata + daemon Lua) est
				complet sur le papier mais <strong>cherche encore ses premiers testeurs</strong>.
			</p>
		</header>

		<div class="table-wrap" use:reveal>
			<table class="matrix">
				<thead>
					<tr>
						<th class="feat-col">Fonctionnalité</th>
						<th>
							<i class="icon-windows"></i>
							<span class="os-name">Windows</span>
							<span class="os-driver">AutoHotkey v2</span>
						</th>
						<th>
							<i class="icon-appleinc"></i>
							<span class="os-name">macOS</span>
							<span class="os-driver">Hammerspoon</span>
						</th>
						<th>
							<i class="icon-linux"></i>
							<span class="os-name">Linux</span>
							<span class="os-driver">kanata + Lua · alpha</span>
						</th>
					</tr>
				</thead>
				<tbody>
					{#each matrix as row, i}
						<tr style="--row: {i};">
							<td class="feat-col">{row.label}</td>
							{#each [row.win, row.mac, row.linux] as status}
								{@const c = cell(status)}
								<td class="cell {c.cls}">{c.text}</td>
							{/each}
						</tr>
					{/each}
				</tbody>
			</table>
		</div>

		<p class="legend" use:reveal>
			<span class="lg ok">✓ fonctionnel</span>
			<span class="lg note">texte = nuance</span>
			<span class="lg warn">α = implémenté, jamais testé en conditions réelles</span>
			<span class="lg off">— = absent</span>
		</p>

		<!-- Per-OS bonuses (exclusive features that are not bundled apps) -->
		<div class="bonus-grid">
			<article class="ep-card bonus-card" use:reveal>
				<h3><i class="icon-windows bonus-icon"></i> En bonus sur Windows</h3>
				<ul class="bonus-list">
					<li>
						<strong>Ergopti sans installation.</strong> Le driver peut <em>émuler</em> la disposition
						Ergopti par-dessus votre layout actuel — aucun installateur, aucun droit admin. Idéal au
						bureau ou sur un poste verrouillé.
					</li>
					<li>
						<strong>Le meilleur d’Ergopti, même en AZERTY ou Bépo.</strong> Sans changer de
						disposition, profitez de la couche de symboles AltGr d’Ergopti et des
						<em>chiffres en accès direct</em> — deux des plus gros gains de la disposition, disponibles
						partout.
					</li>
				</ul>
			</article>

			<article class="ep-card bonus-card" use:reveal={{ delay: 90 }}>
				<h3><i class="icon-appleinc bonus-icon"></i> En bonus sur macOS</h3>
				<ul class="bonus-list">
					<li>
						<strong>Backend MLX (Apple Silicon).</strong> Inférence IA locale accélérée par la puce Apple
						— des prédictions plus rapides, toujours sans passer par le cloud.
					</li>
					<li>
						<strong>Moteur de gestes intégral.</strong> 36 emplacements de gestes trackpad et 3 axes
						continus, là où Windows en propose 10.
					</li>
				</ul>
			</article>
		</div>

		<!-- macOS bundled apps — showcased with their real bundle icons -->
		<div class="apps-showcase" use:reveal>
			<h3 class="apps-title"><i class="icon-appleinc"></i> Applications macOS incluses</h3>
			<p class="apps-lead">
				Des utilitaires signés Ergopti, livrés directement dans le driver macOS — rien de plus à
				installer.
			</p>
			<div class="apps-grid">
				{#each macosApps as app, i (app.id)}
					<article class="ep-card app-card" use:reveal={{ delay: (i % 3) * 70 }}>
						<div class="app-icon" aria-hidden="true">
							{#if app.icon}{@html app.icon}{:else}<span class="app-monogram">{app.name.charAt(0)}</span
								>{/if}
						</div>
						<div class="app-text">
							<h4>{app.name}</h4>
							<p>{app.description}</p>
						</div>
					</article>
				{/each}
			</div>
			<p class="apps-note">
				Applications et descriptions extraites automatiquement des bundles embarqués dans le driver.
			</p>
		</div>

		<aside class="linux-callout ep-card" use:reveal>
			<h3>🐧 Vous utilisez Linux ? On vous cherche.</h3>
			<p>
				Le driver Linux existe : 16 000 lignes de Lua, kanata pour les tap-holds, hotstrings via le
				moteur partagé, IA Ollama, métriques SQLite. Mais <strong
					>personne ne l’a encore fait tourner en conditions réelles</strong
				>
				— il lui faut des testeurs avant d’être recommandable. Si vous voulez essuyer les plâtres,
				<a href="https://github.com/adrienm7/ergopti" target="_blank" rel="noopener"
					>ouvrez une issue sur GitHub</a
				> : chaque retour fera avancer le support.
			</p>
		</aside>

		<!-- Final CTA -->
		<div class="cta-card" use:reveal>
			<div class="cta-glow" aria-hidden="true"></div>
			<h2 class="cta-title">{t('Vos doigts vous diront merci.')}</h2>
			<p class="cta-sub">
				Installez <ErgoptiPlus></ErgoptiPlus>, lancez-le, tapez <code>ct★</code> — et regardez
				<span class="cta-demo">c’était</span> s’écrire tout seul. Le reste suivra.
			</p>
			<div class="cta-buttons">
				<a
					class={ui.osStyle === 'windows' ? 'btn btn-primary' : 'btn btn-secondary'}
					href={urlWindows}
					download={!!ui.release}
				>
					<i class="icon-windows"></i><span>Windows</span>
				</a>
				<a
					class={ui.osStyle === 'macos' ? 'btn btn-primary' : 'btn btn-secondary'}
					href={urlMacos}
					download={!!ui.release}
				>
					<i class="icon-appleinc"></i><span>macOS</span>
				</a>
				<a
					class={ui.osStyle === 'linux' ? 'btn btn-primary' : 'btn btn-secondary'}
					href={urlKanata}
					download={!!ui.release}
				>
					<i class="icon-linux"></i><span>Linux <small>(alpha)</small></span>
				</a>
			</div>
			<p class="cta-meta">
				{#if ui.release}<span class="cta-version">{ui.release.tag}</span>{/if}
				{#if ui.repo}
					<a
						class="cta-gh"
						href="https://github.com/adrienm7/ergopti"
						target="_blank"
						rel="noopener">{t('★ {n} sur GitHub', { n: ui.repo.stars })}</a
					>
				{/if}
			</p>
			<p class="cta-foot">
				<a href="utilisation" class="cta-link"
					>{@html t('Vous tapez déjà en Ergopti&nbsp;? Installez la disposition pour le combo complet →')}</a
				>
			</p>
		</div>
	</div>
</section>

<style>
	/* ─── Matrix ────────────────────────────────────────────── */

	.table-wrap {
		background: linear-gradient(180deg, rgba(255, 255, 255, 0.05), rgba(255, 255, 255, 0.02));
		border: 1px solid var(--border);
		border-radius: var(--radius-lg);
		overflow-x: auto;
	}

	.matrix {
		border-collapse: collapse;
		min-width: 640px;
		width: 100%;
	}

	.matrix th,
	.matrix td {
		border-bottom: 1px solid var(--border);
		padding: 11px 16px;
		text-align: center;
	}

	.matrix tbody tr:last-child td {
		border-bottom: 0;
	}

	.matrix tbody tr {
		transition: background-color 0.2s var(--ease);
	}

	.matrix tbody tr:hover {
		background: rgba(255, 255, 255, 0.03);
	}

	.matrix th {
		padding-block: 16px;
	}

	.matrix th i {
		display: block;
		font-size: 1.3rem;
		margin: 0 auto 6px;
	}

	.matrix th .icon-windows {
		color: #31beff;
	}

	.matrix th .icon-appleinc {
		color: #e8e8ed;
	}

	.matrix th .icon-linux {
		color: #ffc107;
	}

	.os-name {
		display: block;
		font-size: 0.95rem;
		font-weight: 700;
	}

	.os-driver {
		color: var(--ink-faint);
		display: block;
		font-size: 0.72rem;
		font-weight: 500;
	}

	.feat-col {
		font-size: 0.9rem;
		text-align: left !important;
	}

	td.feat-col {
		color: var(--ink-soft);
	}

	.cell.ok {
		color: #4ade80;
		font-weight: 700;
	}

	.cell.off {
		color: rgba(255, 255, 255, 0.25);
	}

	.cell.warn {
		color: #ffc107;
		font-weight: 700;
	}

	.cell.note {
		color: var(--ink-soft);
		font-size: 0.8rem;
	}

	/* The matrix "checks itself": status cells pop in row-by-row when the table
	 * scrolls into view. Guarded so cells stay visible without JS or with
	 * reduced motion (the enclosing .reveal already handles the safe fade). */
	@media (prefers-reduced-motion: no-preference) {
		.table-wrap.is-visible .cell {
			animation: cell-in 0.5s var(--ease-out) both;
			animation-delay: calc(var(--row, 0) * 55ms + 120ms);
		}
	}

	@keyframes cell-in {
		from {
			opacity: 0;
			transform: scale(0.55);
		}
		to {
			opacity: 1;
			transform: none;
		}
	}

	.legend {
		color: var(--ink-faint);
		display: flex;
		flex-wrap: wrap;
		font-size: 0.78rem;
		gap: 8px 18px;
		justify-content: center;
		margin: 14px 0 0;
		text-align: center;
	}

	.lg.ok {
		color: #4ade80;
	}
	.lg.warn {
		color: #ffc107;
	}
	.lg.off {
		color: rgba(255, 255, 255, 0.35);
	}

	/* ─── Per-OS bonuses ────────────────────────────────────── */

	.bonus-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(2, 1fr);
		margin-top: 26px;
	}

	.bonus-card h3 {
		align-items: center;
		display: flex;
		gap: 10px;
		margin-bottom: 12px;
	}

	.bonus-icon {
		font-size: 1.15rem;
	}

	.bonus-card .icon-windows {
		color: #31beff;
	}

	.bonus-card .icon-appleinc {
		color: #e8e8ed;
	}

	.bonus-list {
		display: flex;
		flex-direction: column;
		gap: 12px;
		list-style: none;
	}

	.bonus-list li {
		color: var(--ink-soft);
		font-size: 0.92rem;
		line-height: 1.6;
	}

	@media (max-width: 880px) {
		.bonus-grid {
			grid-template-columns: 1fr;
		}
	}

	/* ─── macOS apps showcase ───────────────────────────────── */

	.apps-showcase {
		margin-top: 28px;
	}

	.apps-title {
		align-items: center;
		display: flex;
		font-size: 1.1rem;
		gap: 10px;
		justify-content: center;
	}

	.apps-title .icon-appleinc {
		color: #e8e8ed;
	}

	.apps-lead {
		color: var(--ink-soft);
		font-size: 0.9rem;
		margin: 6px auto 18px;
		max-width: 560px;
		text-align: center;
	}

	.apps-grid {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
	}

	.app-card {
		align-items: center;
		display: flex;
		gap: 14px;
		text-align: left;
	}

	.app-icon {
		border-radius: 22%;
		flex-shrink: 0;
		height: 56px;
		overflow: hidden;
		width: 56px;
	}

	/* The inlined bundle SVG is injected via {@html}, so it escapes Svelte's
	 * style scoping — reach it with :global to make it fill the icon slot. */
	.app-icon :global(svg) {
		display: block;
		height: 100%;
		width: 100%;
	}

	.app-monogram {
		align-items: center;
		background: linear-gradient(135deg, var(--accent-blue-deep), var(--accent-cyan));
		color: #fff;
		display: flex;
		font-size: 1.5rem;
		font-weight: 800;
		height: 100%;
		justify-content: center;
		width: 100%;
	}

	.app-text h4 {
		font-size: 1rem;
		margin: 0 0 3px;
	}

	.app-text p {
		color: var(--ink-soft);
		font-size: 0.86rem;
		line-height: 1.5;
		margin: 0;
	}

	.apps-note {
		color: var(--ink-faint);
		font-size: 0.78rem;
		margin: 16px 0 0;
		text-align: center;
	}

	/* ─── Linux callout ─────────────────────────────────────── */

	.linux-callout {
		--accent: #ffc107;
		border-color: rgba(255, 193, 7, 0.25);
		margin: 26px auto 0;
		max-width: 780px;
	}

	.linux-callout h3 {
		margin-bottom: 8px;
	}

	.linux-callout a {
		color: var(--accent-blue);
	}

	/* ─── Final CTA ─────────────────────────────────────────── */

	/* The card must visibly outrank every other block on the page: a brighter
	 * layered surface, a stronger accent border, an outer glow and an inset
	 * top highlight — the "buy box" of the page. */
	.cta-card {
		/* Keep the blue wash faint — the emphasis comes from the border and
		 * outer glow, and text must stay high-contrast on the surface */
		background:
			radial-gradient(120% 140% at 50% 0%, rgba(48, 136, 237, 0.08), transparent 55%),
			linear-gradient(180deg, rgba(255, 255, 255, 0.07), rgba(255, 255, 255, 0.03));
		border: 1px solid rgba(49, 190, 255, 0.5);
		border-radius: var(--radius-lg);
		box-shadow:
			0 0 90px -28px rgba(49, 190, 255, 0.55),
			0 26px 60px -32px rgba(0, 0, 0, 0.65),
			inset 0 1px 0 rgba(255, 255, 255, 0.14);
		margin-top: clamp(48px, 7vw, 80px);
		overflow: hidden;
		padding: clamp(40px, 6vw, 72px) clamp(20px, 4vw, 48px);
		position: relative;
		text-align: center;
	}

	/* Edge-only glow: the blue lives at the card's rim, never behind the
	 * text — white copy stays on a dark surface for full contrast */
	.cta-glow {
		background:
			radial-gradient(90% 55% at 50% -12%, rgba(48, 136, 237, 0.18), transparent 55%),
			radial-gradient(70% 45% at 75% 112%, rgba(2, 201, 219, 0.1), transparent 60%);
		inset: 0;
		pointer-events: none;
		position: absolute;
	}

	.cta-title {
		background: linear-gradient(180deg, #fff 30%, rgba(255, 255, 255, 0.6));
		-webkit-background-clip: text;
		background-clip: text;
		font-size: clamp(1.9rem, 4.5vw, 3rem);
		font-weight: 800;
		letter-spacing: -0.02em;
		margin: 0 0 12px;
		/* Keeps descenders inside the painted clip area */
		padding-bottom: 0.12em;
		position: relative;
		text-align: center;
		-webkit-text-fill-color: transparent;
	}

	.cta-sub {
		color: var(--ink-soft);
		font-size: 1.02rem;
		margin: 0 auto 26px;
		max-width: 560px;
		position: relative;
		text-align: center;
	}

	/* The live-expansion word: the same small chip as the <code> input right
	 * before it, but tinted magic-key red — input chip in, output chip out */
	.cta-demo {
		background: rgba(229, 57, 53, 0.16);
		border: 1px solid rgba(229, 57, 53, 0.5);
		border-radius: 6px;
		color: var(--ink);
		font-family: 'SF Mono', 'Cascadia Code', Menlo, Consolas, monospace;
		font-size: 0.88em;
		font-weight: 700;
		padding: 1px 6px;
		white-space: nowrap;
	}

	/* Version + GitHub proof — quiet plain text, chip-free */
	.cta-meta {
		align-items: center;
		color: var(--ink-faint);
		display: flex;
		flex-wrap: wrap;
		font-size: 0.8rem;
		gap: 14px;
		justify-content: center;
		margin: 14px 0 0;
		position: relative;
	}

	.cta-version {
		font-weight: 600;
	}

	.cta-gh {
		color: var(--ink-faint);
		font-weight: 600;
		text-decoration: none;
	}

	.cta-gh:hover {
		color: var(--ink);
		text-decoration: underline;
	}

	.cta-buttons {
		display: flex;
		flex-wrap: wrap;
		gap: 12px;
		justify-content: center;
		position: relative;
	}

	.cta-buttons small {
		font-weight: 500;
		opacity: 0.75;
	}

	.cta-foot {
		color: var(--ink-faint);
		font-size: 0.85rem;
		margin: 20px 0 0;
		position: relative;
		text-align: center;
	}

	.cta-link {
		color: var(--accent-blue);
		text-decoration: none;
	}

	.cta-link:hover {
		text-decoration: underline;
	}
</style>
