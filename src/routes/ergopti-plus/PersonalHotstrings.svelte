<!-- src/routes/ergopti-plus/PersonalHotstrings.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Personal & Dynamic Hotstrings
DESCRIPTION:
The "your own shortcuts" story: TOML-backed personal hotstrings added in one
click from the menu, and @-prefixed dynamic hotstrings computed at fire time
(dates, personal info).

FEATURES & RATIONALE:
1. Sales Angle: the shipped catalog is the base; what converts users is
   adding THEIR signature/IBAN in 5 seconds without touching code.
==============================================================================
-->

<script>
	import { reveal } from './reveal.js';

	const personalExamples = [
		{ trig: 'np★', out: 'Adrien Moyaux', desc: 'Nom complet' },
		{ trig: 'em★', out: 'adrien@exemple.fr', desc: 'E-mail' },
		{ trig: 'tel★', out: '+33 6 12 34 56 78', desc: 'Téléphone' },
		{ trig: 'sig★', out: 'Cordialement, Adrien', desc: 'Signature' },
		{ trig: 'ad★', out: '15 rue Lafayette, Paris', desc: 'Adresse' },
		{ trig: 'iban★', out: 'FR76 1234 5678 9012…', desc: 'IBAN' }
	];

	const dynamicExamples = [
		{ trig: '@dt', out: '21/07/2026', desc: 'Date du jour' },
		{ trig: '@dtL', out: '21 juillet 2026', desc: 'Date en lettres' },
		{ trig: '@ph', out: '06 12 34 56 78', desc: 'Téléphone configuré' },
		{ trig: '@np★', out: 'Moyaux ⇥ Adrien', desc: 'Remplissage de formulaire' }
	];

	const steps = [
		'Sélectionnez un texte que vous tapez souvent.',
		'Ouvrez le menu → Hotstrings personnels.',
		'Choisissez un déclencheur (ex : sig★).',
		'C’est actif — sans redémarrer le driver.'
	];
</script>

<section class="personal" id="perso-hotstrings" style="--section-accent: #8e8e93;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Vos propres raccourcis</p>
			<h2>Et ceux que <em>vous</em> tapez tous les jours.</h2>
			<p class="lead">
				Signature, IBAN, formules récurrentes : ajoutez vos hotstrings <strong>en un clic</strong>
				depuis le menu — stockés dans un simple fichier TOML, rechargés à la volée.
			</p>
		</header>

		<div class="personal-grid">
			<article class="ep-card" use:reveal>
				<h3>Ajout en 5 secondes</h3>
				<ol class="steps">
					{#each steps as s, i}
						<li><span class="step-num">{i + 1}</span><span>{s}</span></li>
					{/each}
				</ol>
				<ul class="rows">
					{#each personalExamples as p}
						<li>
							<span class="hs-key">{p.trig}</span>
							<span class="hs-arrow">→</span>
							<span class="hs-out">{p.out}</span>
							<span class="hs-desc">{p.desc}</span>
						</li>
					{/each}
				</ul>
			</article>

			<article class="ep-card" use:reveal={{ delay: 90 }}>
				<h3>Hotstrings dynamiques</h3>
				<p class="card-lead">
					Certaines valeurs changent tous les jours (la date) ou ne doivent pas être écrites en dur
					(téléphone, IBAN). Le préfixe <code>@</code> les calcule <strong>au moment précis</strong>
					du déclenchement, depuis l’éditeur d’informations personnelles.
				</p>
				<ul class="rows">
					{#each dynamicExamples as d}
						<li>
							<span class="hs-key">{d.trig}</span>
							<span class="hs-arrow">→</span>
							<span class="hs-out">{d.out}</span>
							<span class="hs-desc">{d.desc}</span>
						</li>
					{/each}
				</ul>
				<p class="card-foot">
					Nom, e-mail, téléphone, adresse, IBAN : tout est centralisé dans une seule fenêtre — les
					hotstrings dynamiques s’en servent automatiquement.
				</p>
			</article>
		</div>
	</div>
</section>

<style>
	.personal-grid {
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(2, 1fr);
	}

	.steps {
		display: flex;
		flex-direction: column;
		gap: 9px;
		list-style: none;
		margin: 0 0 18px;
	}

	.steps li {
		align-items: baseline;
		color: var(--ink-soft);
		display: flex;
		font-size: 0.92rem;
		gap: 10px;
	}

	.step-num {
		align-items: center;
		background: rgba(49, 190, 255, 0.12);
		border: 1px solid rgba(49, 190, 255, 0.3);
		border-radius: 50%;
		color: var(--accent-blue);
		display: inline-flex;
		flex-shrink: 0;
		font-size: 0.72rem;
		font-weight: 800;
		height: 22px;
		justify-content: center;
		position: relative;
		top: 2px;
		width: 22px;
	}

	.rows {
		display: flex;
		flex-direction: column;
		gap: 9px;
		list-style: none;
	}

	.rows li {
		align-items: baseline;
		display: flex;
		flex-wrap: wrap;
		gap: 6px 10px;
	}

	.rows .hs-desc {
		margin-left: auto;
	}

	.card-lead {
		margin-bottom: 16px;
	}

	.card-foot {
		border-top: 1px solid var(--border);
		color: var(--ink-faint);
		font-size: 0.85rem;
		margin-top: 16px;
		padding-top: 14px;
	}

	@media (max-width: 880px) {
		.personal-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
