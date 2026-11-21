<!-- src/routes/ergopti-plus/KeyboardPower.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Augmented Keyboard (Tap-Holds & Layers)
DESCRIPTION:
The physical-key superpowers: the 7 real tap-hold keys from the shared
defaults TOML, the real HJKL navigation layer, and the small power moves
(CapsWord, word deletion, wrap-symbols).

FEATURES & RATIONALE:
1. Truthful Mappings: every tap/hold pair and layer mapping shown here is
   read from _shared/tap_hold/data/defaults.toml — the previous page displayed
   outdated mappings.
==============================================================================
-->

<script>
	import { isActionOnPlatform } from './action-platforms.js';
	import { countup } from './countup.js';
	import { reveal } from './reveal.js';
	import { ui } from './state.svelte.js';
	import { localized, t } from './i18n.svelte.js';

	/**
	 * @type {{
	 *   actionGroups: Array<{title: string, titleEn: string, sections: Array<{title: string, titleEn: string, actions: Array<{id: string, label: string, labelEn: string, platform: string, axis: boolean}>}>}>
	 * }}
	 */
	let { actionGroups } = $props();

	// Map the page's OS toggle to the catalog's platform tags. Linux only
	// gets the cross-platform entries (its gesture engine is still alpha).
	let platformTag = $derived(
		ui.osStyle === 'macos' ? 'hs' : ui.osStyle === 'windows' ? 'ahk' : null
	);

	/**
	 * Keep only the actions available on the selected OS.
	 * @param {Array<{platform: string}>} actions
	 * @returns {Array<object>}
	 */
	function forPlatform(actions) {
		return actions.filter((a) => isActionOnPlatform(a.platform, platformTag));
	}

	// Same group → section structure as the driver's action picker, with
	// empty sections and groups pruned after the platform filter. Titles and
	// labels come from the drivers' own French and English catalogues.
	let visibleGroups = $derived(
		actionGroups
			.map((g) => ({
				key: g.title,
				title: localized(g.title, g.titleEn),
				sections: g.sections
					.map((s) => ({
						key: s.title,
						title: localized(s.title, s.titleEn),
						actions: forPlatform(s.actions)
					}))
					.filter((s) => s.actions.length > 0)
			}))
			.filter((g) => g.sections.length > 0)
	);
	let visibleCount = $derived(
		visibleGroups.reduce((n, g) => n + g.sections.reduce((m, s) => m + s.actions.length, 0), 0)
	);

	// The 7 shared tap-hold keys — mirrors _shared/tap_hold/data/defaults.toml.
	// $derived so the cards re-translate the instant the language toggles.
	let tapHolds = $derived([
		{
			key: 'CapsLock',
			tap: { label: t('Entrée'), icon: '↩' },
			hold: { label: 'Ctrl / Cmd', icon: '⌃' },
			note: t('La touche la plus accessible de la home-row devient validation ET modificateur.')
		},
		{
			key: 'LShift',
			tap: { label: t('Copier'), icon: '⧉' },
			hold: { label: 'Shift', icon: '⇧' },
			note: t('Copier d’un seul appui sur une touche que votre auriculaire connaît déjà.')
		},
		{
			key: 'LCtrl',
			tap: { label: t('Coller'), icon: '↧' },
			hold: { label: 'Ctrl', icon: '⌃' },
			note: t('Coller sans quitter la position de repos, sans accord à deux mains.')
		},
		{
			key: 'LAlt',
			tap: { label: t('Retour arrière'), icon: '⌫' },
			hold: { label: t('Couche navigation'), icon: '☷' },
			note: t('Backspace sous le pouce ; maintenu, il ouvre le layer de navigation ci-dessous.')
		},
		{
			key: 'RCtrl',
			tap: { label: t('Shift one-shot'), icon: '⇧¹' },
			hold: { label: 'Shift', icon: '⇧' },
			note: t(
				'Un appui = la prochaine lettre en majuscule. Fini le Shift maintenu pour une seule lettre.'
			)
		},
		{
			key: 'AltGr',
			tap: { label: 'Tab', icon: '⇥' },
			hold: { label: 'AltGr', icon: '⌥' },
			note: t('Tab au pouce droit — l’indentation et la navigation de formulaires sans étirement.')
		},
		{
			key: 'Tab',
			tap: { label: t('Alt-Tab (écran)'), icon: '⧉⇄' },
			hold: { label: 'Alt', icon: '⎇' },
			note: t('Bascule d’application sur le moniteur courant, en un seul appui.')
		}
	]);

	// Real "nav" layer mappings from the shared TOML (HJKL + editing keys).
	let navLayer = $derived([
		{ key: 'h', label: '←', desc: t('Gauche') },
		{ key: 'j', label: '↓', desc: t('Bas') },
		{ key: 'k', label: '↑', desc: t('Haut') },
		{ key: 'l', label: '→', desc: t('Droite') },
		{ key: 'u', label: '⇞', desc: t('Page haut') },
		{ key: 'd', label: '⇟', desc: t('Page bas') },
		{ key: 'g', label: '⇱', desc: t('Début') },
		{ key: '⇧g', label: '⇲', desc: t('Fin') },
		{ key: '⌫', label: t('⌫mot'), desc: t('Effacer mot') },
		{ key: '⌦', label: t('⌦mot'), desc: t('Suppr. mot') }
	]);

	// A curated shortlist of the standout actions — the ones that solve a real
	// daily annoyance. Labels/emojis mirror the shared catalog (actions.toml +
	// fr.json); the "pain" copy is what makes them land. The full catalog below
	// lists everything; this grid sells the highlights.
	let superActions = $derived([
		{
			icon: '🖱',
			title: t('Téléporter la souris'),
			body: t(
				'Le curseur saute sur l’écran voisin d’un seul tap — fini de deviner vers quel bord le pousser pour changer de moniteur.'
			)
		},
		{
			icon: '🔦',
			title: t('Surbrillance du curseur'),
			body: t(
				'Perdu votre souris sur trois écrans ? Un halo la fait ressortir à l’instant — parfait aussi en présentation.'
			)
		},
		{
			icon: '📸',
			title: t('Capture en un tap'),
			body: t(
				'Région, fenêtre, plein écran ou OCR — sur la touche à gauche du 1, sans chercher le raccourci système.'
			)
		},
		{
			icon: '☰',
			title: t('Sélectionner la ligne'),
			body: t('La ligne entière sélectionnée d’un geste, sans viser au pixel ni tripler-cliquer.')
		},
		{
			icon: '🌐',
			title: t('Ouvrir lien ou chemin'),
			body: t(
				'Ouvre l’URL ou le chemin de fichier local sous le curseur — où qu’il se trouve dans le texte.'
			)
		},
		{
			icon: 'AA',
			title: t('Changer la casse'),
			body: t(
				'Bascule la sélection en MAJUSCULES, minuscules ou Casse De Titre — plus besoin de retaper.'
			)
		}
	]);

	let powerMoves = $derived([
		{
			icon: '⇪',
			title: 'CapsWord',
			body: t(
				'MAJUSCULES sur le mot en cours uniquement — le shift virtuel se relâche à l’espace. Parfait pour les acronymes (NASA, TODO).'
			)
		},
		{
			icon: '⌫',
			title: t('Suppression de mot'),
			body: t('Un geste efface le mot entier — idéal pour annuler une expansion d’un coup.')
		},
		{
			icon: '“ ”',
			title: t('Encadrer la sélection'),
			body: t(
				'Sélectionnez du texte, tapez <code>"</code>, <code>(</code> ou <code>[</code> : la sélection est encadrée par la paire correspondante.'
			)
		},
		{
			icon: '★',
			title: t('Répéteur intelligent'),
			body: t('Sans abréviation en attente, ★ double la lettre précédente — les doublons sans SFB.')
		}
	]);
</script>

<section class="keyboard" id="ep-tapholds" style="--section-accent: #fb8c00;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Tap-Holds</p>
			<h2>{t('Sept touches à double vie.')}</h2>
			<p class="lead">
				{@html t(
					'Un appui bref déclenche une action, un maintien conserve le rôle de modificateur. La même logique sur les deux OS : <strong>les mêmes doigts</strong> déclenchent les mêmes gestes, avec le modificateur natif de chaque plateforme — <kbd>Ctrl</kbd> sur Windows, <kbd>⌘</kbd> sur macOS. L’objectif : <strong>une expérience unifiée</strong>, quel que soit l’ordinateur devant vous. Ce sont les défauts livrés ; chaque touche, action et délai se change depuis le menu.'
				)}
			</p>
		</header>

		<div class="tap-grid">
			{#each tapHolds as hold, i}
				<article
					class="ep-card ep-card--hover tap-card"
					style="--accent: #fb8c00;"
					use:reveal={{ delay: (i % 4) * 70 }}
				>
					<div class="tap-keycap"><kbd>{hold.key}</kbd></div>
					<dl class="tap-rows">
						<div class="tap-row">
							<dt class="tap-pill">Tap</dt>
							<dd class="tap-glyph" aria-hidden="true">{hold.tap.icon}</dd>
							<dd class="tap-action">{hold.tap.label}</dd>
						</div>
						<div class="tap-row tap-row--hold">
							<dt class="tap-pill tap-pill--hold">Hold</dt>
							<dd class="tap-glyph" aria-hidden="true">{hold.hold.icon}</dd>
							<dd class="tap-action">{hold.hold.label}</dd>
						</div>
					</dl>
					<p class="tap-note">{hold.note}</p>
				</article>
			{/each}

			<article class="ep-card tap-card tap-card--nav" use:reveal={{ delay: 280 }}>
				<h3>
					{t('Layer navigation')}
					<small class="nav-hint">{@html t('(maintenir <kbd>LAlt</kbd>)')}</small>
				</h3>
				<ul class="nav-grid">
					{#each navLayer as n}
						<li class="nav-cell">
							<kbd>{n.key}</kbd>
							<span class="nav-glyph" aria-hidden="true">{n.label}</span>
							<span class="nav-desc">{n.desc}</span>
						</li>
					{/each}
				</ul>
				<p class="tap-note">
					{t(
						'Flèches sur HJKL, pages, début/fin de ligne, effacement par mot — la main ne quitte jamais la position de repos.'
					)}
				</p>
			</article>
		</div>

		<div class="power-grid">
			{#each powerMoves as p, i}
				<article class="ep-card power-card" use:reveal={{ delay: i * 70 }}>
					<span class="power-icon" aria-hidden="true">{p.icon}</span>
					<h4>{p.title}</h4>
					<p>{@html p.body}</p>
				</article>
			{/each}
		</div>
	</div>
</section>

<section class="keyboard" id="ep-raccourcis" style="--section-accent: #fb8c00;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">{t('Raccourcis')}</p>
			<h2>{t('Des actions qui règlent de vraies galères.')}</h2>
			<p class="lead">
				{t(
					'Bien au-delà du copier-coller : voici quelques-unes des actions les plus utiles — chacune assignable à n’importe quelle touche, tap-hold ou geste.'
				)}
			</p>
		</header>

		<div class="super-actions">
			{#each superActions as a, i}
				<article class="ep-card ep-card--hover super-action" use:reveal={{ delay: (i % 3) * 70 }}>
					<span class="sa-icon" aria-hidden="true">{a.icon}</span>
					<div class="sa-text">
						<h3>{a.title}</h3>
						<p>{a.body}</p>
					</div>
				</article>
			{/each}
		</div>

		<!-- Shared action catalog, structured like the driver's picker and
		     filtered by the page's OS toggle -->
		<section class="actions-block">
			<h3 class="actions-title" use:reveal>
				<span use:countup={visibleCount}>{visibleCount}</span>
				{t('actions à assigner. À n’importe quelle touche ou geste.')}
			</h3>
			<p class="actions-lead" use:reveal>
				{@html t(
					'Tap-holds, gestes trackpad et raccourcis piochent dans le même catalogue d’actions, défini dans <strong>un seul fichier partagé par les trois drivers</strong>. Mêmes groupes, mêmes sections que dans le sélecteur du driver — filtrés ici pour <strong>{os}</strong> ; changez d’OS en haut de page pour voir la différence.',
					{ os: ui.osStyle === 'macos' ? 'macOS' : ui.osStyle === 'linux' ? 'Linux' : 'Windows' }
				)}
			</p>
			<div class="actions-groups">
				{#each visibleGroups as g, gi (g.key)}
					<article class="ep-card actions-group" use:reveal={{ delay: (gi % 4) * 60 }}>
						<h4 class="group-title">{g.title}</h4>
						{#each g.sections as s (g.key + s.key)}
							{#if s.title}<h5 class="section-title">{s.title}</h5>{/if}
							<ul class="actions-cloud">
								{#each s.actions as a (a.id)}
									<li class="action-chip" class:axis={a.axis} title={a.id}>
										{localized(a.label, a.labelEn)}
										{#if a.axis}<span class="axis-tag">{t('axe')}</span>{/if}
									</li>
								{/each}
							</ul>
						{/each}
					</article>
				{/each}
			</div>
		</section>
	</div>
</section>

<style>
	/* Four cards per row at most, each at least 13rem wide: larger text takes
	   fewer columns instead of cutting the cards' words. */
	.tap-grid {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(auto-fit, minmax(min(100%, max(13rem, 22%)), 1fr));
		margin-bottom: 26px;
	}

	.tap-card {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.tap-card--nav {
		grid-column: 1 / -1;
	}

	.tap-keycap kbd {
		font-size: 1rem;
		padding: 6px 14px;
	}

	.tap-rows {
		display: flex;
		flex-direction: column;
		gap: 7px;
		margin: 0;
	}

	.tap-row {
		align-items: center;
		display: flex;
		gap: 9px;
	}

	.tap-pill {
		background: rgba(251, 140, 0, 0.15);
		border: 1px solid rgba(251, 140, 0, 0.4);
		border-radius: 999px;
		color: #ffb45e;
		flex-shrink: 0;
		font-size: 0.64rem;
		font-weight: 800;
		letter-spacing: 0.07em;
		min-width: 44px;
		padding: 2px 0;
		text-align: center;
		text-transform: uppercase;
	}

	.tap-pill--hold {
		background: rgba(255, 255, 255, 0.06);
		border-color: var(--border-strong);
		color: var(--ink-faint);
	}

	/* In em, so the glyph's column grows with the text instead of the glyph
	   spilling over the action's name. */
	.tap-glyph {
		flex-shrink: 0;
		font-size: 1rem;
		margin: 0;
		min-width: 1.6em;
	}

	.tap-action {
		font-size: 0.9rem;
		font-weight: 650;
		margin: 0;
		min-width: 0;
		overflow-wrap: anywhere;
	}

	.tap-note {
		border-top: 1px solid var(--border);
		color: var(--ink-faint);
		font-size: 0.8rem;
		line-height: 1.5;
		margin: auto 0 0;
		padding-top: 10px;
	}

	/* ─── Nav layer ─────────────────────────────────────────── */

	.tap-card--nav h3 {
		font-size: 1.05rem;
	}

	.nav-hint {
		color: var(--ink-faint);
		font-size: 0.85rem;
		font-weight: 500;
	}

	/* Cells at least 4.5rem wide (the rem follows the text size): five per row
	   at the default size, fewer when the text grows, never cut. */
	.nav-grid {
		display: grid;
		gap: 8px;
		grid-template-columns: repeat(auto-fit, minmax(min(100%, 4.5rem), 1fr));
		line-height: inherit;
		list-style: none;
		text-align: inherit;
	}

	.nav-cell {
		align-items: center;
		background: rgba(255, 255, 255, 0.04);
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		display: flex;
		flex-direction: column;
		gap: 3px;
		line-height: inherit;
		margin: 0;
		padding: 10px 6px;
		text-align: inherit;
	}

	.nav-glyph {
		color: #ffb45e;
		font-size: 0.95rem;
		font-weight: 700;
	}

	.nav-desc {
		color: var(--ink-faint);
		font-size: 0.7rem;
		overflow-wrap: anywhere;
		text-align: center;
	}

	/* ─── Power moves ───────────────────────────────────────── */

	/* Four cards per row at most, each at least 13rem wide so that larger
	   text takes fewer columns instead of cutting the cards' words. */
	.power-grid {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(auto-fit, minmax(min(100%, max(13rem, 22%)), 1fr));
	}

	.power-card {
		text-align: left;
	}

	.power-icon {
		color: #ffb45e;
		display: inline-block;
		font-size: 1.3rem;
		margin-bottom: 10px;
	}

	/* ─── Standout actions ──────────────────────────────────── */

	.super-actions {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(3, 1fr);
		margin-bottom: clamp(30px, 4.5vw, 48px);
	}

	.super-action {
		--accent: #fb8c00;
		align-items: flex-start;
		display: flex;
		gap: 14px;
	}

	.sa-icon {
		flex-shrink: 0;
		font-size: 1.5rem;
		line-height: 1.15;
	}

	.sa-text h3 {
		font-size: 1rem;
		margin: 0 0 4px;
	}

	.sa-text p {
		font-size: 0.88rem;
	}

	@media (max-width: 900px) {
		.super-actions {
			grid-template-columns: repeat(2, 1fr);
		}
	}

	@media (max-width: 560px) {
		.super-actions {
			grid-template-columns: 1fr;
		}
	}

	/* ─── Action catalog ────────────────────────────────────── */

	/* The catalog is a sub-section of its own: cancel the page's section
	   padding, positioning and chapter divider (ergopti-plus.css). */
	.actions-block {
		margin-top: clamp(28px, 4vw, 44px);
		padding-block: 0;
		position: static;
	}

	section.actions-block:not(.hero)::before {
		content: none;
	}

	.actions-title {
		font-size: 1.25rem;
		font-weight: 700;
		margin-bottom: 8px;
		text-align: center;
	}

	.actions-lead {
		color: var(--ink-soft);
		font-size: 0.92rem;
		line-height: 1.6;
		margin: 0 auto 18px;
		max-width: min(660px, 55ch);
		text-align: center;
	}

	/* Masonry-style packing: CSS multi-column flows the group cards to fill
	 * each column top-to-bottom instead of a rigid grid whose rows align to
	 * the tallest card — that alignment left large vertical gaps. The
	 * "240px 3" shorthand auto-fits as many ~240px columns as fit, capped at
	 * 3, so the layout goes 1 → 2 → 3 columns purely on available width, no
	 * media query needed. A tall group naturally sits beside two short ones. */
	.actions-groups {
		column-gap: 14px;
		columns: 240px 3;
	}

	.actions-group {
		--accent: #fb8c00;
		/* Never split a group across a column boundary */
		break-inside: avoid;
		display: inline-block;
		margin-bottom: 14px;
		width: 100%;
	}

	.group-title {
		border-bottom: 1px solid var(--border);
		font-size: 1rem;
		font-weight: 700;
		margin: 0 0 10px;
		padding-bottom: 8px;
	}

	.section-title {
		color: var(--ink-faint);
		font-size: 0.72rem;
		font-weight: 700;
		letter-spacing: 0.08em;
		margin: 12px 0 7px;
		text-transform: uppercase;
	}

	.actions-cloud {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		list-style: none;
	}

	.action-chip {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: 999px;
		color: var(--ink-soft);
		font-size: 0.8rem;
		padding: 4px 12px;
		transition: border-color 0.25s var(--ease);
	}

	.action-chip:hover {
		border-color: rgba(251, 140, 0, 0.45);
	}

	.axis-tag {
		background: rgba(251, 140, 0, 0.15);
		border-radius: 999px;
		color: #ffb45e;
		font-size: 0.62rem;
		font-weight: 700;
		margin-left: 5px;
		padding: 1px 6px;
		text-transform: uppercase;
	}

	@media (max-width: 720px) {
		.actions-groups {
			grid-template-columns: 1fr;
		}
	}
</style>
