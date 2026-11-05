<!-- src/routes/ergopti-plus/Platforms.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Platforms & Download
DESCRIPTION:
The three-driver story, a configuration inventory projected from the shared
manifest, the Linux alpha disclaimer, and the download call-to-action.

A declaration does not prove runtime behavior or the absence of an equivalent
under another configuration path.
==============================================================================
-->

<script>
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
	import { assetUrlOrPage, LINUX_APPIMAGE_ASSET } from '#lib/js/getGitHubRelease.js';
	import { ui } from './state.svelte.js';
	import { reveal } from './reveal.js';
	import { t, i18n } from './i18n.svelte.js';
	import matrix from './feature-inventory.json';
	import actions from './action-inventory.json';
	import inputs from './input-inventory.json';
	import menuGaps from './menu-gaps.json';
	import behaviors from './behavior-inventory.json';

	/** @type {{macosApps: Array<{id: string, name: string, description: string}>}} */
	let { macosApps } = $props();

	let urlWindows = $derived(ui.release?.url('ErgoptiPlus.exe') ?? '#');
	let urlMacos = $derived(ui.release?.url('ErgoptiPlus.app.zip') ?? '#');
	let urlLinux = $derived(assetUrlOrPage(ui.release, LINUX_APPIMAGE_ASSET));
</script>

<section class="platforms" id="ep-telecharger" style="--section-accent: var(--accent-blue);">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Trois systèmes</p>
			<h2>{t('Trois systèmes, un projet.')}</h2>
			<p class="lead">
				{t(
					'Les entrées ci-dessous proviennent du manifeste partagé. Une entrée absente peut avoir un équivalent sous un autre nom ; sa présence ne garantit pas son fonctionnement en conditions réelles.'
				)}
			</p>
		</header>

		<details class="table-wrap" use:reveal>
			<summary>{t('Inventaire des réglages et fonctionnalités')} ({matrix.length})</summary>
			<table class="matrix">
				<thead>
					<tr>
						<th class="feat-col">{t('Fonctionnalité ou réglage')}</th>
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
							<span class="os-driver">Lua · alpha</span>
						</th>
					</tr>
				</thead>
				<tbody>
					{#each matrix as row, i}
						<tr style="--row: {i};">
							<td class="feat-col"
								>{row.labels[i18n.lang]} <small><code>{row.path}</code></small></td
							>
							{#each [row.platforms.windows, row.platforms.macos, row.platforms.linux] as available}
								<td
									class:ok={available}
									class:off={!available}
									class="cell"
									title={!available ? row.reason?.[i18n.lang] : undefined}
									>{available ? '✓' : '—'}</td
								>
							{/each}
						</tr>
					{/each}
				</tbody>
			</table>
		</details>

		<details class="table-wrap" use:reveal>
			<summary>{t('Comportements examinés dans le code')} ({behaviors.length})</summary>
			<p class="lead">
				{t(
					'Ce catalogue complémentaire couvre les comportements examinés. Il ne constitue pas un inventaire exhaustif ni une garantie de fonctionnement dans chaque application.'
				)}
			</p>
			<table class="matrix">
				<thead>
					<tr>
						<th class="feat-col">{t('Fonctionnalité ou réglage')}</th>
						<th>Windows</th>
						<th>macOS</th>
						<th>Linux</th>
					</tr>
				</thead>
				<tbody>
					{#each behaviors as row}
						<tr>
							<td class="feat-col">{row.labels[i18n.lang]}</td>
							{#each ['windows', 'macos', 'linux'] as os}
								<td>
									<span class:ok={row.platforms[os]} class:off={!row.platforms[os]} class="cell"
										>{row.platforms[os] ? '✓' : '—'}</span
									>
									<small class="behavior-note">{row.notes[os][i18n.lang]}</small>
								</td>
							{/each}
						</tr>
					{/each}
				</tbody>
			</table>
		</details>

		<details class="table-wrap" use:reveal>
			<summary>{t('Inventaire des actions configurables')} ({actions.length})</summary>
			<table class="matrix">
				<thead>
					<tr>
						<th class="feat-col">{t('Action')}</th>
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
							<span class="os-driver">Lua · alpha</span>
						</th>
					</tr>
				</thead>
				<tbody>
					{#each actions as row, i}
						<tr style="--row: {i};">
							<td class="feat-col"
								>{row.labels[i18n.lang]} <small><code>{row.path}</code></small></td
							>
							{#each ['windows', 'macos', 'linux'] as os}
								{@const available = row.platforms[os]}
								<td
									class:ok={available}
									class:off={!available}
									class="cell"
									title={row.reasons[os]?.[i18n.lang]}>{available ? '✓' : '—'}</td
								>
							{/each}
						</tr>
					{/each}
				</tbody>
			</table>
		</details>

		<details class="table-wrap" use:reveal>
			<summary>{t('Touches tap-hold par système')} ({inputs.length})</summary>
			<table class="matrix">
				<thead>
					<tr>
						<th class="feat-col">{t('Action')}</th>
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
							<span class="os-driver">Lua · alpha</span>
						</th>
					</tr>
				</thead>
				<tbody>
					{#each inputs as row, i}
						<tr style="--row: {i};">
							<td class="feat-col"
								>{row.labels[i18n.lang]} <small><code>{row.path}</code></small></td
							>
							{#each ['windows', 'macos', 'linux'] as os}
								{@const available = row.platforms[os]}
								<td
									class:ok={available}
									class:off={!available}
									class="cell"
									title={row.reasons[os]?.[i18n.lang]}>{available ? '✓' : '—'}</td
								>
							{/each}
						</tr>
					{/each}
				</tbody>
			</table>
		</details>

		<details class="table-wrap" use:reveal>
			<summary>{t('Options de menu propres à certains systèmes')} ({actions.length})</summary>
			<table class="matrix">
				<thead>
					<tr>
						<th class="feat-col">{t('Option')}</th>
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
							<span class="os-driver">Lua · alpha</span>
						</th>
					</tr>
				</thead>
				<tbody>
					{#each menuGaps as row, i}
						<tr style="--row: {i};">
							<td class="feat-col"
								>{row.labels[i18n.lang]} <small><code>{row.path}</code></small></td
							>
							{#each ['windows', 'macos', 'linux'] as os}
								{@const available = row.platforms[os]}
								<td
									class:ok={available}
									class:off={!available}
									class="cell"
									title={row.reasons[os]?.[i18n.lang]}>{available ? '✓' : '—'}</td
								>
							{/each}
						</tr>
					{/each}
				</tbody>
			</table>
		</details>

		<p class="legend" use:reveal>
			<span class="lg ok">{t('✓ déclaré pour ce système')}</span>
			<span class="lg off">{t('— entrée non déclarée pour ce système')}</span>
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
							{#if app.icon}{@html app.icon}{:else}<span class="app-monogram"
									>{app.name.charAt(0)}</span
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
				Le driver Linux existe : 16 000 lignes de Lua, tap-holds gérés par le daemon lui-même,
				hotstrings via le moteur partagé, IA Ollama, métriques SQLite. Mais <strong
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
					href={urlLinux}
					download={!!ui.release}
				>
					<i class="icon-linux"></i><span>Linux <small>(alpha)</small></span>
				</a>
			</div>
			<p class="cta-brew">
				{t('Sur macOS, aussi avec Homebrew :')}
				<code>brew install --cask adrienm7/ergopti/ergoptiplus</code>
			</p>
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
					>{@html t(
						'Vous tapez déjà en Ergopti&nbsp;? Installez la disposition pour le combo complet →'
					)}</a
				>
			</p>
		</div>
	</div>
</section>

<style>
	/* ─── Matrix ────────────────────────────────────────────── */

	.table-wrap summary {
		cursor: pointer;
		padding: 16px;
	}

	.feat-col small {
		display: block;
		font-size: 0.75em;
	}

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

	.behavior-note {
		color: var(--ink-soft);
		display: block;
		font-size: 0.78rem;
		line-height: 1.5;
		margin-top: 6px;
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

	.cta-brew {
		color: var(--ink-faint);
		font-size: 0.85rem;
		margin: 14px 0 0;
		overflow-wrap: anywhere;
		position: relative;
		text-align: center;
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
