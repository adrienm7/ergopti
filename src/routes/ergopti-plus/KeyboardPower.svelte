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
   read from _shared/tap_hold/defaults.toml — the previous page displayed
   outdated mappings.
==============================================================================
-->

<script>
	import { reveal } from './reveal.js';
	import { ui } from './state.svelte.js';

	/**
	 * @type {{
	 *   actionGroups: Array<{title: string, sections: Array<{title: string, actions: Array<{id: string, label: string, platform: string, axis: boolean}>}>}>
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
		return actions.filter(
			(a) => a.platform === 'all' || (platformTag !== null && a.platform === platformTag)
		);
	}

	// Same group → section structure as the driver's action picker, with
	// empty sections and groups pruned after the platform filter.
	let visibleGroups = $derived(
		actionGroups
			.map((g) => ({
				title: g.title,
				sections: g.sections
					.map((s) => ({ title: s.title, actions: forPlatform(s.actions) }))
					.filter((s) => s.actions.length > 0)
			}))
			.filter((g) => g.sections.length > 0)
	);
	let visibleCount = $derived(
		visibleGroups.reduce((n, g) => n + g.sections.reduce((m, s) => m + s.actions.length, 0), 0)
	);

	// The 7 shared tap-hold keys — mirrors _shared/tap_hold/defaults.toml.
	const tapHolds = [
		{
			key: 'CapsLock',
			tap: { label: 'Entrée', icon: '↩' },
			hold: { label: 'Ctrl / Cmd', icon: '⌃' },
			note: 'La touche la plus accessible de la home-row devient validation ET modificateur.'
		},
		{
			key: 'LShift',
			tap: { label: 'Copier', icon: '⧉' },
			hold: { label: 'Shift', icon: '⇧' },
			note: 'Copier d’un seul appui sur une touche que votre auriculaire connaît déjà.'
		},
		{
			key: 'LCtrl',
			tap: { label: 'Coller', icon: '↧' },
			hold: { label: 'Ctrl', icon: '⌃' },
			note: 'Coller sans quitter la position de repos, sans accord à deux mains.'
		},
		{
			key: 'LAlt',
			tap: { label: 'Retour arrière', icon: '⌫' },
			hold: { label: 'Couche navigation', icon: '☷' },
			note: 'Backspace sous le pouce ; maintenu, il ouvre le layer de navigation ci-dessous.'
		},
		{
			key: 'RCtrl',
			tap: { label: 'Shift one-shot', icon: '⇧¹' },
			hold: { label: 'Shift', icon: '⇧' },
			note: 'Un appui = la prochaine lettre en majuscule. Fini le Shift maintenu pour une seule lettre.'
		},
		{
			key: 'AltGr',
			tap: { label: 'Tab', icon: '⇥' },
			hold: { label: 'AltGr', icon: '⌥' },
			note: 'Tab au pouce droit — l’indentation et la navigation de formulaires sans étirement.'
		},
		{
			key: 'Tab',
			tap: { label: 'Alt-Tab (écran)', icon: '⧉⇄' },
			hold: { label: 'Alt', icon: '⎇' },
			note: 'Bascule d’application sur le moniteur courant, en un seul appui.'
		}
	];

	// Real "nav" layer mappings from the shared TOML (HJKL + editing keys).
	const navLayer = [
		{ key: 'h', label: '←', desc: 'Gauche' },
		{ key: 'j', label: '↓', desc: 'Bas' },
		{ key: 'k', label: '↑', desc: 'Haut' },
		{ key: 'l', label: '→', desc: 'Droite' },
		{ key: 'u', label: '⇞', desc: 'Page haut' },
		{ key: 'd', label: '⇟', desc: 'Page bas' },
		{ key: 'g', label: '⇱', desc: 'Début' },
		{ key: '⇧g', label: '⇲', desc: 'Fin' },
		{ key: '⌫', label: '⌫mot', desc: 'Effacer mot' },
		{ key: '⌦', label: '⌦mot', desc: 'Suppr. mot' }
	];

	// A curated shortlist of the standout actions — the ones that solve a real
	// daily annoyance. Labels/emojis mirror the shared catalog (actions.toml +
	// fr.json); the "pain" copy is what makes them land. The full catalog below
	// lists everything; this grid sells the highlights.
	const superActions = [
		{
			icon: '🖱',
			title: 'Téléporter la souris',
			body: 'Le curseur saute sur l’écran voisin d’un seul tap — fini de deviner vers quel bord le pousser pour changer de moniteur.'
		},
		{
			icon: '🔦',
			title: 'Surbrillance du curseur',
			body: 'Perdu votre souris sur trois écrans ? Un halo la fait ressortir à l’instant — parfait aussi en présentation.'
		},
		{
			icon: '📸',
			title: 'Capture en un tap',
			body: 'Région, fenêtre, plein écran ou OCR — sur la touche à gauche du 1, sans chercher le raccourci système.'
		},
		{
			icon: '☰',
			title: 'Sélectionner la ligne',
			body: 'La ligne entière sélectionnée d’un geste, sans viser au pixel ni tripler-cliquer.'
		},
		{
			icon: '🌐',
			title: 'Ouvrir lien ou chemin',
			body: 'Ouvre l’URL ou le chemin de fichier local sous le curseur — où qu’il se trouve dans le texte.'
		},
		{
			icon: 'AA',
			title: 'Changer la casse',
			body: 'Bascule la sélection en MAJUSCULES, minuscules ou Casse De Titre — plus besoin de retaper.'
		}
	];

	const powerMoves = [
		{
			icon: '⇪',
			title: 'CapsWord',
			body: 'MAJUSCULES sur le mot en cours uniquement — le shift virtuel se relâche à l’espace. Parfait pour les acronymes (NASA, TODO).'
		},
		{
			icon: '⌫',
			title: 'Suppression de mot',
			body: 'Un geste efface le mot entier — idéal pour annuler une expansion d’un coup.'
		},
		{
			icon: '“ ”',
			title: 'Encadrer la sélection',
			body: 'Sélectionnez du texte, tapez <code>"</code>, <code>(</code> ou <code>[</code> : la sélection est encadrée par la paire correspondante.'
		},
		{
			icon: '★',
			title: 'Répéteur intelligent',
			body: 'Sans abréviation en attente, ★ double la lettre précédente — les doublons sans SFB.'
		}
	];
</script>

<section class="keyboard" id="ep-tapholds" style="--section-accent: #fb8c00;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Tap-Holds</p>
			<h2>Sept touches à double vie.</h2>
			<p class="lead">
				Un appui bref déclenche une action, un maintien conserve le rôle de modificateur. La même
				logique sur les deux OS : <strong>les mêmes doigts</strong> déclenchent les mêmes gestes, avec
				le modificateur natif de chaque plateforme — <kbd>Ctrl</kbd> sur Windows, <kbd>⌘</kbd> sur
				macOS. L’objectif : <strong>une expérience unifiée</strong>, quel que soit l’ordinateur devant
				vous. Ce sont les défauts livrés ; chaque touche, action et délai se change depuis le menu.
			</p>
		</header>

		<div class="tap-grid">
			{#each tapHolds as t, i}
				<article
					class="ep-card ep-card--hover tap-card"
					style="--accent: #fb8c00;"
					use:reveal={{ delay: (i % 4) * 70 }}
				>
					<div class="tap-keycap"><kbd>{t.key}</kbd></div>
					<div class="tap-rows">
						<div class="tap-row">
							<span class="tap-pill">Tap</span>
							<span class="tap-glyph" aria-hidden="true">{t.tap.icon}</span>
							<span class="tap-action">{t.tap.label}</span>
						</div>
						<div class="tap-row tap-row--hold">
							<span class="tap-pill tap-pill--hold">Hold</span>
							<span class="tap-glyph" aria-hidden="true">{t.hold.icon}</span>
							<span class="tap-action">{t.hold.label}</span>
						</div>
					</div>
					<p class="tap-note">{t.note}</p>
				</article>
			{/each}

			<article class="ep-card tap-card tap-card--nav" use:reveal={{ delay: 280 }}>
				<h3>Layer navigation <span class="nav-hint">(maintenir <kbd>LAlt</kbd>)</span></h3>
				<div class="nav-grid">
					{#each navLayer as n}
						<div class="nav-cell">
							<kbd>{n.key}</kbd>
							<span class="nav-glyph" aria-hidden="true">{n.label}</span>
							<span class="nav-desc">{n.desc}</span>
						</div>
					{/each}
				</div>
				<p class="tap-note">
					Flèches sur HJKL, pages, début/fin de ligne, effacement par mot — la main ne quitte jamais
					la position de repos.
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
			<p class="kicker">Raccourcis</p>
			<h2>Des actions qui règlent de vraies galères.</h2>
			<p class="lead">
				Bien au-delà du copier-coller : voici quelques-unes des actions les plus utiles — chacune
				assignable à n’importe quelle touche, tap-hold ou geste.
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
		<div class="actions-block">
			<h3 class="actions-title" use:reveal>
				{visibleCount} actions à assigner. À n’importe quelle touche ou geste.
			</h3>
			<p class="actions-lead" use:reveal>
				Tap-holds, gestes trackpad et raccourcis piochent dans le même catalogue d’actions, défini
				dans <strong>un seul fichier partagé par les trois drivers</strong>. Mêmes groupes, mêmes
				sections que dans le sélecteur du driver — filtrés ici pour
				<strong
					>{ui.osStyle === 'macos' ? 'macOS' : ui.osStyle === 'linux' ? 'Linux' : 'Windows'}</strong
				> ; changez d’OS en haut de page pour voir la différence.
			</p>
			<div class="actions-groups">
				{#each visibleGroups as g, gi (g.title)}
					<article class="ep-card actions-group" use:reveal={{ delay: (gi % 4) * 60 }}>
						<h4 class="group-title">{g.title}</h4>
						{#each g.sections as s (g.title + s.title)}
							{#if s.title}<h5 class="section-title">{s.title}</h5>{/if}
							<ul class="actions-cloud">
								{#each s.actions as a (a.id)}
									<li class="action-chip" class:axis={a.axis} title={a.id}>
										{a.label}
										{#if a.axis}<span class="axis-tag">axe</span>{/if}
									</li>
								{/each}
							</ul>
						{/each}
					</article>
				{/each}
			</div>
		</div>
	</div>
</section>

<style>
	.tap-grid {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(4, 1fr);
		margin-bottom: 26px;
	}

	.tap-card {
		display: flex;
		flex-direction: column;
		gap: 12px;
	}

	.tap-card--nav {
		grid-column: span 4;
	}

	.tap-keycap kbd {
		font-size: 1rem;
		padding: 6px 14px;
	}

	.tap-rows {
		display: flex;
		flex-direction: column;
		gap: 7px;
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

	.tap-glyph {
		font-size: 1rem;
		width: 26px;
	}

	.tap-action {
		font-size: 0.9rem;
		font-weight: 650;
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

	.nav-grid {
		display: grid;
		gap: 8px;
		grid-template-columns: repeat(5, 1fr);
	}

	.nav-cell {
		align-items: center;
		background: rgba(255, 255, 255, 0.04);
		border: 1px solid var(--border);
		border-radius: var(--radius-sm);
		display: flex;
		flex-direction: column;
		gap: 3px;
		padding: 10px 6px;
	}

	.nav-glyph {
		color: #ffb45e;
		font-size: 0.95rem;
		font-weight: 700;
	}

	.nav-desc {
		color: var(--ink-faint);
		font-size: 0.7rem;
		text-align: center;
	}

	/* ─── Power moves ───────────────────────────────────────── */

	.power-grid {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(4, 1fr);
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

	.actions-block {
		margin-top: clamp(28px, 4vw, 44px);
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
		max-width: 660px;
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

	@media (max-width: 1100px) {
		.tap-grid {
			grid-template-columns: repeat(2, 1fr);
		}

		.tap-card--nav {
			grid-column: span 2;
		}

		.power-grid {
			grid-template-columns: repeat(2, 1fr);
		}
	}

	@media (max-width: 720px) {
		.tap-grid,
		.power-grid,
		.actions-groups {
			grid-template-columns: 1fr;
		}

		.tap-card--nav {
			grid-column: span 1;
		}

		.nav-grid {
			grid-template-columns: repeat(3, 1fr);
		}
	}
</style>
