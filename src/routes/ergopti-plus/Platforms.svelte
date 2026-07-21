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
		{ label: 'Spotlight curseur (présentations)', win: 'yes', mac: 'no', linux: 'no' }
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

<section class="platforms" id="telecharger" style="--section-accent: var(--accent-blue);">
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
					{#each matrix as row}
						<tr>
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
			<h2 class="cta-title">Prêt à taper moins ?</h2>
			<p class="cta-sub">
				Téléchargez <ErgoptiPlus></ErgoptiPlus>{#if ui.release}&nbsp;<span class="cta-version"
						>{ui.release.tag}</span
					>{/if}, lancez-le, tapez <code>ct★</code>. Le reste suivra.
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
				<a class="btn btn-secondary" href={urlKanata} download={!!ui.release}>
					<i class="icon-linux"></i><span>Linux <small>(alpha)</small></span>
				</a>
			</div>
			<p class="cta-foot">
				Gratuit · Open-source · Sans compte —
				<a href="utilisation" class="cta-link"
					>et installez la disposition Ergopti pour le combo complet →</a
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

	.cta-card {
		border: 1px solid rgba(49, 190, 255, 0.3);
		border-radius: var(--radius-lg);
		margin-top: clamp(48px, 7vw, 80px);
		overflow: hidden;
		padding: clamp(40px, 6vw, 72px) clamp(20px, 4vw, 48px);
		position: relative;
		text-align: center;
	}

	.cta-glow {
		background:
			radial-gradient(ellipse at 30% 0%, rgba(48, 136, 237, 0.25), transparent 60%),
			radial-gradient(ellipse at 70% 100%, rgba(2, 201, 219, 0.18), transparent 60%);
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
		position: relative;
		text-align: center;
		-webkit-text-fill-color: transparent;
	}

	.cta-sub {
		color: var(--ink-soft);
		font-size: 1.02rem;
		margin: 0 0 26px;
		position: relative;
		text-align: center;
	}

	.cta-version {
		background: rgba(49, 190, 255, 0.12);
		border: 1px solid rgba(49, 190, 255, 0.3);
		border-radius: 999px;
		color: var(--accent-blue);
		font-size: 0.82rem;
		font-weight: 600;
		padding: 2px 10px;
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
