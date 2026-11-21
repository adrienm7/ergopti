<!-- src/routes/ergopti-plus/ErgoptiExclusives.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Ergopti-Layout Exclusives
DESCRIPTION:
Everything that only makes sense ON the Ergopti layout: bigram rolls, SFB
reduction, the comma super-key, à-suffixes and programming symbol rolls.
Kept to two nesting levels maximum (section > card) — the old version
stacked four bordered boxes here.

FEATURES & RATIONALE:
1. Clear Boundary: a visitor on AZERTY must instantly see that everything
   ABOVE works for them, and this section is the Ergopti-only bonus.
2. Language: the section follows the page's language through t(); its
   example words keep their own language (WCAG 3.1.2), English or French.
==============================================================================
-->

<script>
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
	import KeyboardBasis from '#lib/keyboard/KeyboardBasis.svelte';
	import KeyboardControls from '#lib/keyboard/controls/KeyboardControls.svelte';
	import { reveal } from './reveal.js';
	import { t } from './i18n.svelte.js';

	// $derived so the cards re-translate the instant the language toggles.
	let bigramCards = $derived([
		{
			title: t('Roulements de bigrammes'),
			color: '#1e88e5',
			lead: t(
				'Des séquences inconfortables remplacées par des roulements fluides sur doigts adjacents. Vous tapez ce qui est confortable, le mot correct sort.'
			),
			rows: [
				{ trig: 'sx', out: 'sk', words: 'ask, task, desk', lang: 'en' },
				{ trig: 'cx', out: 'ck', words: 'back, check', lang: 'en' },
				{ trig: 'hc', out: 'wh', words: 'what, when, while', lang: 'en' },
				{ trig: 'nt’', out: 'n’t', words: 'don’t, can’t', lang: 'en' }
			]
		},
		{
			title: t('Réduction des SFBs'),
			color: '#e53935',
			lead: t(
				'La virgule devient une super touche morte qui neutralise les derniers bigrammes à même doigt. Les touches É/È/Ê s’en chargent côté gauche.'
			),
			rows: [
				{ trig: ',t', out: 'pt', words: 'aptement', lang: 'fr' },
				{ trig: 'éà', out: 'ié', words: 'ciel', lang: 'fr' },
				{ trig: 'àé', out: 'éi', words: 'antérieur', lang: 'fr' },
				{ trig: 'êe', out: 'œ', words: 'sœur', lang: 'fr' }
			]
		},
		{
			title: t('Symboles de programmation'),
			color: '#8e44ad',
			lead: t(
				'Les combinaisons pénibles du code deviennent des roulements vers l’intérieur sur la home-row d’Ergopti.'
			),
			rows: [
				{ trig: '$=', out: '=>', words: 'fat arrow', lang: 'en' },
				{ trig: '+?', out: '->', words: 'Rust, types', lang: 'en' },
				{ trig: '!#', out: '!=', words: t('différent') },
				{ trig: '<@', out: '</', words: t('fermeture HTML') }
			]
		}
	]);

	let superKeys = $derived([
		{
			title: t(', + voyelle = J'),
			body: t(
				'Le <kbd>j</kbd> cède sa place à la touche ★. La séquence <code>,</code>+voyelle — inexistante en français — produit le <code>j</code> : <code>,a</code> → <em>ja</em>, <code>,e</code> → <em>je</em>.'
			)
		},
		{
			title: t(', + consonne = lettres rares'),
			body: t(
				'<code>,è</code> → <em>z</em>, <code>,y</code> → <em>k</em>, <code>,s</code> → <em>q</em>, <code>,c</code> → <em>ç</em>. Les lettres rares restent à une frappe du repos.'
			)
		},
		{
			title: t('Q + voyelle = QU'),
			body: t(
				'En français, <kbd>q</kbd> implique presque toujours <kbd>u</kbd> : tapez <code>qe</code>, <code>qoi</code> — le <em>u</em> s’insère tout seul.'
			)
		},
		{
			title: t('ê = circonflexe direct'),
			body: t(
				'Une touche dédiée pour le cas le plus fréquent, et <code>êa</code>, <code>êi</code>, <code>êo</code>, <code>êu</code> pour â, î, ô, û.'
			)
		},
		{
			title: t('Suffixes en à'),
			body: t(
				'<code>às</code> → <em>ement</em>, <code>àt</code> → <em>ation</em>, <code>àr</code> → <em>eur</em>… Les terminaisons fréquentes en deux frappes au lieu de cinq.'
			)
		},
		{
			title: t('Apostrophe typographique'),
			body: t(
				"Dans du texte, <kbd>'</kbd> produit <em>’</em> ; dans du code, elle reste droite. Aucun réglage."
			)
		}
	]);
</script>

<section class="exclusives" id="ep-ergopti" style="--section-accent: #ffc107;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">{t('⚡ Bonus disposition Ergopti')}</p>
			<h2>{t('L’autre moitié du gain.')}</h2>
			<p class="lead">
				<strong
					><ErgoptiPlus></ErgoptiPlus> {t('fonctionne sur n’importe quelle disposition')}</strong
				>
				{t(
					'— AZERTY, QWERTY, Bépo… Tout ce qui précède marche sans rien changer à votre clavier. Les fonctionnalités ci-dessous, elles, exploitent les positions exactes des touches de la disposition'
				)}
				<a href="./" class="ergo-link">Ergopti</a>{t(
					' : adoptez la disposition et Ergopti+ les active automatiquement.'
				)}
			</p>
		</header>

		<figure class="ergo-keyboard" use:reveal>
			<KeyboardBasis id="presentation_plus" />
			<div class="ergo-keyboard-controls">
				<KeyboardControls id="presentation_plus" />
			</div>
			<figcaption>
				<p class="ergo-keyboard-caption">
					{t(
						'La disposition Ergopti et ses couches — explorez la couche AltGr, la touche magique et les symboles de programmation.'
					)}
				</p>
			</figcaption>
		</figure>

		<div class="bigram-grid">
			{#each bigramCards as cat, i}
				<article
					class="ep-card bigram-card"
					style="--accent: {cat.color};"
					use:reveal={{ delay: i * 80 }}
				>
					<h3><span class="bigram-dot" aria-hidden="true"></span>{cat.title}</h3>
					<p class="bigram-lead">{cat.lead}</p>
					<ul class="bigram-rows">
						{#each cat.rows as r}
							<li>
								<span class="hs-key">{r.trig}</span>
								<span class="hs-arrow">→</span>
								<span class="hs-out">{r.out}</span>
								<span class="hs-desc" lang={r.lang}>{r.words}</span>
							</li>
						{/each}
					</ul>
				</article>
			{/each}
		</div>

		<div class="super-grid">
			{#each superKeys as s, i}
				<article class="ep-card super-card" use:reveal={{ delay: (i % 3) * 70 }}>
					<h4>{s.title}</h4>
					<p>{@html s.body}</p>
				</article>
			{/each}
		</div>
	</div>
</section>

<style>
	/* Reused interactive layout viewer from the legacy page — shows the
	 * Ergopti layers (AltGr, magic key, programming symbols). */
	.ergo-keyboard {
		margin: 0 auto 28px;
		max-width: 940px;
		text-align: center;
	}

	.ergo-keyboard-controls {
		margin-top: 12px;
	}

	.ergo-keyboard-caption {
		color: var(--ink-faint);
		font-size: 0.82rem;
		margin: 12px auto 0;
		max-width: min(620px, 55ch);
	}

	.bigram-grid {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(3, 1fr);
		margin-bottom: 26px;
	}

	.bigram-card h3 {
		align-items: center;
		display: flex;
		gap: 9px;
	}

	.bigram-dot {
		background: var(--accent);
		border-radius: 50%;
		box-shadow: 0 0 12px color-mix(in srgb, var(--accent) 60%, transparent);
		flex-shrink: 0;
		height: 9px;
		width: 9px;
	}

	.bigram-lead {
		color: var(--ink-faint);
		font-size: 0.85rem;
		line-height: 1.55;
		margin: 0 0 14px;
	}

	.bigram-rows {
		display: flex;
		flex-direction: column;
		gap: 8px;
		list-style: none;
	}

	.bigram-rows li {
		align-items: baseline;
		display: flex;
		flex-wrap: wrap;
		gap: 5px 9px;
	}

	.bigram-rows .hs-desc {
		margin-left: auto;
	}

	.super-grid {
		display: grid;
		gap: 12px;
		grid-template-columns: repeat(3, 1fr);
	}

	.ergo-link {
		color: var(--accent-blue);
		text-decoration: none;
	}

	.ergo-link:hover {
		text-decoration: underline;
	}

	@media (max-width: 1100px) {
		.bigram-grid,
		.super-grid {
			grid-template-columns: repeat(2, 1fr);
		}
	}

	@media (max-width: 720px) {
		.bigram-grid,
		.super-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
