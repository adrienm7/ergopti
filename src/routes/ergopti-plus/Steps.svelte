<!-- src/routes/ergopti-plus/Steps.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Getting Started in 3 Steps
DESCRIPTION:
A short, reassuring onboarding narrative right before the download CTA:
install, launch, type. Removes the "what happens after I download?" friction.
==============================================================================
-->

<script>
	import { reveal } from './reveal.js';
	import { t } from './i18n.svelte.js';

	// $derived so the cards re-translate the instant the language toggles.
	let steps = $derived([
		{
			n: 1,
			icon: '⬇️',
			title: t('Téléchargez et lancez'),
			body: t(
				'Un exécutable pour Windows, une app pour macOS. Aucun compte, aucun droit administrateur nécessaire dans la plupart des cas.'
			)
		},
		{
			n: 2,
			icon: '⌨️',
			title: t('Tapez comme d’habitude'),
			body: t(
				'Rien à réapprendre. Vos hotstrings, corrections et prédictions sont actifs immédiatement, sur votre disposition actuelle.'
			)
		},
		{
			n: 3,
			icon: '🎛️',
			title: t('Ajustez à votre rythme'),
			body: t(
				'Activez une fonctionnalité à la fois depuis le menu — tap-holds, gestes, IA. Rien n’est imposé, tout est optionnel.'
			)
		}
	]);
</script>

<section class="steps" id="ep-demarrer" style="--section-accent: #02c9db;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">{t('Prise en main')}</p>
			<h2>{t('Opérationnel en trois minutes.')}</h2>
			<p class="lead">
				{t(
					'Pas de configuration obligatoire, pas de courbe d’apprentissage : ça marche dès le lancement, et ça grandit avec vous.'
				)}
			</p>
		</header>

		<ol class="steps-grid">
			{#each steps as s, i}
				<li class="ep-card step-card" use:reveal={{ delay: i * 90 }}>
					<span class="step-n" aria-hidden="true">{s.n}</span>
					<span class="step-ico" aria-hidden="true">{s.icon}</span>
					<h3>{s.title}</h3>
					<p>{s.body}</p>
				</li>
			{/each}
		</ol>
	</div>
</section>

<style>
	.steps-grid {
		counter-reset: step;
		display: grid;
		gap: 16px;
		grid-template-columns: repeat(3, 1fr);
		list-style: none;
		margin: 0 auto;
		max-width: 900px;
		padding: 0;
	}

	.step-card {
		--accent: #02c9db;
		position: relative;
	}

	.step-n {
		background: rgba(2, 201, 219, 0.14);
		border: 1px solid rgba(2, 201, 219, 0.4);
		border-radius: 50%;
		color: #5fe3f0;
		font-size: 0.85rem;
		font-weight: 800;
		height: 30px;
		inset: 16px 16px auto auto;
		line-height: 28px;
		position: absolute;
		text-align: center;
		width: 30px;
	}

	.step-ico {
		display: block;
		font-size: 1.7rem;
		margin-bottom: 12px;
	}

	@media (max-width: 780px) {
		.steps-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
