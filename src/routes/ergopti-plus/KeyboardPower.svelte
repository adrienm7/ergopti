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

<section class="keyboard" id="clavier" style="--section-accent: #fb8c00;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Clavier augmenté</p>
			<h2>Sept touches à double vie.</h2>
			<p class="lead">
				Un appui bref déclenche une action, un maintien conserve le rôle de modificateur. Sept
				touches définies dans un seul fichier partagé par les trois drivers — délais réglables au
				centième de seconde.
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
		.power-grid {
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
