<!-- src/routes/ergopti-plus/Privacy.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — Privacy & Trust
DESCRIPTION:
Privacy is the core differentiator, but it was scattered across the AI and
metrics sections. This dedicated block states it plainly: everything is local,
nothing is collected, and the whole thing is auditable.
==============================================================================
-->

<script>
	import { reveal } from './reveal.js';
	import { t } from './i18n.svelte.js';

	// $derived so the cards re-translate the instant the language toggles.
	let points = $derived([
		{
			icon: '🔒',
			title: t('100 % local'),
			body: t(
				'Frappe, hotstrings, prédictions, métriques : tout est calculé et stocké sur votre machine. Aucun serveur, aucun cloud par défaut.'
			)
		},
		{
			icon: '🚫',
			title: t('Aucune télémétrie'),
			body: t(
				'Pas de compte, pas de tracking, pas de « statistiques anonymes ». Le logiciel ne vous observe pas.'
			)
		},
		{
			icon: '🙈',
			title: t('Mots de passe ignorés'),
			body: t(
				'Les champs de saisie sécurisés sont exclus de toute capture et de tout enregistrement de frappe.'
			)
		},
		{
			icon: '🔑',
			title: t('Clés d’API chiffrées'),
			body: t(
				'Si vous utilisez un modèle distant (optionnel), la clé est chiffrée localement (Trousseau macOS, DPAPI Windows) — jamais en clair.'
			)
		},
		{
			icon: '🗄️',
			title: t('Vos données vous appartiennent'),
			body: t(
				'Les métriques vivent dans une base SQLite locale que vous pouvez lire, exporter ou supprimer à tout moment.'
			)
		},
		{
			icon: '👁️',
			title: t('Auditable'),
			body: t(
				'Le code est open-source et public. N’importe qui peut vérifier ce que fait réellement le driver.'
			)
		}
	]);
</script>

<section class="privacy" id="ep-confidentialite" style="--section-accent: #34d399;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">{t('Vie privée')}</p>
			<h2>{t('Puissant parce que local. Pas malgré ça.')}</h2>
			<p class="lead">
				{t(
					'Le pari d’Ergopti+ : tout ce qui rend la frappe plus intelligente tourne chez vous. Aucune donnée n’a besoin d’en sortir — et aucune n’en sort.'
				)}
			</p>
		</header>

		<div class="privacy-grid">
			{#each points as p, i}
				<article class="ep-card privacy-card" use:reveal={{ delay: (i % 3) * 70 }}>
					<span class="privacy-ico" aria-hidden="true">{p.icon}</span>
					<h3>{p.title}</h3>
					<p>{p.body}</p>
				</article>
			{/each}
		</div>
	</div>
</section>

<style>
	.privacy-grid {
		display: grid;
		gap: 14px;
		grid-template-columns: repeat(3, 1fr);
	}

	.privacy-card {
		--accent: #34d399;
	}

	.privacy-ico {
		display: block;
		font-size: 1.5rem;
		margin-bottom: 10px;
	}

	@media (max-width: 900px) {
		.privacy-grid {
			grid-template-columns: repeat(2, 1fr);
		}
	}

	@media (max-width: 560px) {
		.privacy-grid {
			grid-template-columns: 1fr;
		}
	}
</style>
