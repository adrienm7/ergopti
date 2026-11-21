<!-- src/routes/ergopti-plus/Trackpad.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Trackpad Gestures
DESCRIPTION:
The multi-touch gesture engine: 36 assignable slots + 3 continuous axes
(measured from the shared gestures/actions.toml), with the flagship
3-finger-tap word definition highlighted.

FEATURES & RATIONALE:
1. Honest Platform Labels: macOS has the full engine; Windows exposes 10
   assignable slots — stated as-is instead of a vague checkmark.
==============================================================================
-->

<script>
	import { countup } from './countup.js';
	import { reveal } from './reveal.js';
	import { t } from './i18n.svelte.js';

	// $derived so the cards re-translate the instant the language toggles.
	let gestures = $derived([
		{
			fingers: t('3 doigts'),
			type: 'Tap',
			action: t('Définition du mot'),
			note: t('Posez trois doigts sur un mot : sa définition apparaît. Le geste signature.')
		},
		{
			fingers: t('3 doigts'),
			type: 'Swipe ← →',
			action: t('Mot précédent / suivant'),
			note: t('Avancez mot par mot dans n’importe quel champ texte.')
		},
		{
			fingers: t('3 doigts'),
			type: 'Swipe ↑ ↓',
			action: t('Volume + / −'),
			note: t('Axe continu : plus le geste est long, plus le volume bouge.')
		},
		{
			fingers: t('4 doigts'),
			type: 'Tap',
			action: t('Copier'),
			note: t('Sélectionnez à deux doigts, copiez à quatre — plus rapide que le raccourci.')
		},
		{
			fingers: t('4 doigts'),
			type: 'Swipe ← →',
			action: t('Onglet précédent / suivant'),
			note: t('Navigation d’onglets sans toucher le clavier.')
		},
		{
			fingers: t('5 doigts'),
			type: 'Swipe ↑ ↓',
			action: 'Mission Control / App Switcher',
			note: t('Toutes vos fenêtres d’un geste.')
		}
	]);
</script>

<section class="trackpad" id="ep-trackpad" style="--section-accent: #00bcd4;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">{t('Gestes trackpad')}</p>
			<h2>
				<span use:countup={36}>36</span>
				{t('emplacements de gestes. 3 axes continus.')}
			</h2>
			<p class="lead">
				{t(
					'Le driver intercepte les gestes multi-touch bruts (pas les événements souris) et les associe à l’action de votre choix. Taps et swipes de 2 à 5 doigts, catalogue d’actions intégré, sensibilité réglable par geste.'
				)}
			</p>
		</header>

		<div class="gesture-grid">
			{#each gestures as g, i}
				<article
					class="ep-card ep-card--hover gesture-card"
					style="--accent: #00bcd4;"
					use:reveal={{ delay: (i % 3) * 80 }}
				>
					<div class="gesture-meta">
						<span class="gesture-fingers">{g.fingers}</span>
						<span class="gesture-type">{g.type}</span>
					</div>
					<h3 class="gesture-action">{g.action}</h3>
					<p class="gesture-note">{g.note}</p>
				</article>
			{/each}
		</div>

		<p class="gesture-foot" use:reveal>
			{@html t(
				'Moteur complet sur <strong>macOS</strong> (36 slots + 3 axes, valeurs par défaut ci-dessus) ; <strong>Windows</strong> expose 10 emplacements assignables (taps et swipes 3-4 doigts). Chaque geste est réassignable depuis le menu, ou désactivable.'
			)}
		</p>
	</div>
</section>

<style>
	.gesture-grid {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(3, 1fr);
	}

	.gesture-meta {
		display: flex;
		gap: 8px;
		margin-bottom: 12px;
	}

	.gesture-fingers {
		background: rgba(0, 188, 212, 0.13);
		border: 1px solid rgba(0, 188, 212, 0.4);
		border-radius: 999px;
		color: #6fe3f2;
		font-size: 0.72rem;
		font-weight: 700;
		padding: 3px 10px;
	}

	.gesture-type {
		background: rgba(255, 255, 255, 0.06);
		border: 1px solid var(--border);
		border-radius: 999px;
		color: var(--ink-faint);
		font-size: 0.72rem;
		font-weight: 600;
		padding: 3px 10px;
	}

	/* The card's title keeps its former plain-text look: cancel what the
	   global and card h3 rules (titles.css, ergopti-plus.css) add. */
	.gesture-card .gesture-action {
		color: inherit;
		font-size: 1.02rem;
		font-weight: 700;
		letter-spacing: normal;
		line-height: inherit;
		margin: 0 0 6px;
		overflow-wrap: inherit;
		text-align: inherit;
		-webkit-text-fill-color: inherit;
		text-wrap: inherit;
	}

	.gesture-note {
		color: var(--ink-faint);
		font-size: 0.85rem;
		line-height: 1.55;
	}

	.gesture-foot {
		color: var(--ink-soft);
		font-size: 0.9rem;
		line-height: 1.6;
		margin: 22px auto 0;
		max-width: min(640px, 55ch);
		text-align: center;
	}

	@media (max-width: 880px) {
		.gesture-grid {
			grid-template-columns: repeat(2, 1fr);
		}
	}

	@media (max-width: 560px) {
		.gesture-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
