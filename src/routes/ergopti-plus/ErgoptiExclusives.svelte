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
==============================================================================
-->

<script>
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import { reveal } from './reveal.js';

	const bigramCards = [
		{
			title: 'Roulements de bigrammes',
			color: '#1e88e5',
			lead: 'Des séquences inconfortables remplacées par des roulements fluides sur doigts adjacents. Vous tapez ce qui est confortable, le mot correct sort.',
			rows: [
				{ trig: 'sx', out: 'sk', words: 'ask, task, desk' },
				{ trig: 'cx', out: 'ck', words: 'back, check' },
				{ trig: 'hc', out: 'wh', words: 'what, when, while' },
				{ trig: 'nt’', out: 'n’t', words: 'don’t, can’t' }
			]
		},
		{
			title: 'Réduction des SFBs',
			color: '#e53935',
			lead: 'La virgule devient une super touche morte qui neutralise les derniers bigrammes à même doigt. Les touches É/È/Ê s’en chargent côté gauche.',
			rows: [
				{ trig: ',t', out: 'pt', words: 'aptement' },
				{ trig: 'éà', out: 'ié', words: 'ciel' },
				{ trig: 'àé', out: 'éi', words: 'antérieur' },
				{ trig: 'êe', out: 'œ', words: 'sœur' }
			]
		},
		{
			title: 'Symboles de programmation',
			color: '#8e44ad',
			lead: 'Les combinaisons pénibles du code deviennent des roulements vers l’intérieur sur la home-row d’Ergopti.',
			rows: [
				{ trig: '$=', out: '=>', words: 'fat arrow' },
				{ trig: '+?', out: '->', words: 'Rust, types' },
				{ trig: '!#', out: '!=', words: 'différent' },
				{ trig: '<@', out: '</', words: 'fermeture HTML' }
			]
		}
	];

	const superKeys = [
		{
			title: ', + voyelle = J',
			body: 'Le <kbd>j</kbd> cède sa place à la touche ★. La séquence <code>,</code>+voyelle — inexistante en français — produit le <code>j</code> : <code>,a</code> → <em>ja</em>, <code>,e</code> → <em>je</em>.'
		},
		{
			title: ', + consonne = lettres rares',
			body: '<code>,è</code> → <em>z</em>, <code>,y</code> → <em>k</em>, <code>,s</code> → <em>q</em>, <code>,c</code> → <em>ç</em>. Les lettres rares restent à une frappe du repos.'
		},
		{
			title: 'Q + voyelle = QU',
			body: 'En français, <kbd>q</kbd> implique presque toujours <kbd>u</kbd> : tapez <code>qe</code>, <code>qoi</code> — le <em>u</em> s’insère tout seul.'
		},
		{
			title: 'ê = circonflexe direct',
			body: 'Une touche dédiée pour le cas le plus fréquent, et <code>êa</code>, <code>êi</code>, <code>êo</code>, <code>êu</code> pour â, î, ô, û.'
		},
		{
			title: 'Suffixes en à',
			body: '<code>às</code> → <em>ement</em>, <code>àt</code> → <em>ation</em>, <code>àr</code> → <em>eur</em>… Les terminaisons fréquentes en deux frappes au lieu de cinq.'
		},
		{
			title: 'Apostrophe typographique',
			body: "Dans du texte, <kbd>'</kbd> produit <em>’</em> ; dans du code, elle reste droite. Aucun réglage."
		}
	];
</script>

<section class="exclusives" id="ergopti" style="--section-accent: #ffc107;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">⚡ Bonus disposition Ergopti</p>
			<h2>L’autre moitié du gain.</h2>
			<p class="lead">
				Tout ce qui précède fonctionne sur <strong>n’importe quelle disposition</strong>. Les
				fonctionnalités ci-dessous, elles, exploitent les positions exactes des touches d’<a
					href="./"
					class="ergo-link">Ergopti</a
				>
				— si vous adoptez la disposition,
				<ErgoptiPlus></ErgoptiPlus> les active automatiquement.
			</p>
		</header>

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
								<span class="hs-desc">{r.words}</span>
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
