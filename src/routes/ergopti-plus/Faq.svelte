<!-- src/routes/ergopti-plus/Faq.svelte -->

<!--
==============================================================================
MODULE: Ergopti+ Page — FAQ
DESCRIPTION:
Answers the objections that actually block a download: privacy, typing
latency, app compatibility, uninstall, cost. Built on native <details> so it
needs no JS, stays accessible, and works if scripting is disabled.
==============================================================================
-->

<script>
	import { reveal } from './reveal.js';

	const faqs = [
		{
			q: 'Est-ce que quelque chose part sur Internet ?',
			a: 'Non. Tout — hotstrings, prédictions IA, métriques — est calculé et stocké <strong>sur votre machine</strong>. Les modèles d’IA tournent en local ; si vous branchez une clé d’API distante (optionnel), elle est chiffrée dans le Trousseau macOS ou via DPAPI sur Windows, et vous choisissez explicitement quand l’utiliser.'
		},
		{
			q: 'Est-ce que ça ralentit ma frappe ?',
			a: 'Non perceptiblement. Les expansions sont synchrones et instantanées ; les prédictions IA sont asynchrones et n’interrompent jamais la frappe — une suggestion s’affiche quand elle est prête, et vous l’ignorez ou l’acceptez d’une touche.'
		},
		{
			q: 'Ça marche dans toutes mes applications ?',
			a: 'Oui, le driver agit au niveau du système : navigateur, éditeur de code, messagerie, traitement de texte… Les champs de mot de passe sont volontairement <strong>ignorés</strong>. Quelques applications très verrouillées (certains jeux anti-triche) peuvent bloquer l’injection de touches.'
		},
		{
			q: 'Faut-il utiliser la disposition Ergopti ?',
			a: 'Non. <strong>Tout fonctionne sur n’importe quelle disposition</strong> (AZERTY, QWERTY, Bépo…). La disposition Ergopti débloque des bonus supplémentaires (roulements, super-touches), mais elle est totalement optionnelle.'
		},
		{
			q: 'C’est vraiment gratuit ?',
			a: 'Oui : gratuit, open-source, sans compte et sans télémétrie. Le code est auditable publiquement sur GitHub.'
		},
		{
			q: 'Comment on désinstalle ?',
			a: 'Chaque fonctionnalité se désactive d’un clic dans le menu, et l’application se retire comme n’importe quelle autre. Vos données (base SQLite locale) vous appartiennent et partent avec.'
		},
		{
			q: 'Windows, macOS ou Linux ?',
			a: 'Windows (AutoHotkey) et macOS (Hammerspoon) sont à parité et prêts à l’emploi. Le driver Linux (kanata + daemon Lua) est complet mais en alpha — il cherche ses premiers testeurs.'
		}
	];
</script>

<section class="faq" id="ep-faq" style="--section-accent: #5e9cff;">
	<div class="ep-wrap">
		<header class="section-head" use:reveal>
			<p class="kicker">Questions fréquentes</p>
			<h2>Tout ce qu’on se demande avant d’installer.</h2>
			<p class="lead">
				Confidentialité, performance, compatibilité — les réponses courtes, sans détour.
			</p>
		</header>

		<div class="faq-list">
			{#each faqs as f, i}
				<details class="ep-card faq-item" use:reveal={{ delay: (i % 4) * 50 }}>
					<summary>
						<span class="faq-q">{f.q}</span>
						<span class="faq-chevron" aria-hidden="true"></span>
					</summary>
					<div class="faq-a">
						<p>{@html f.a}</p>
					</div>
				</details>
			{/each}
		</div>
	</div>
</section>

<style>
	.faq-list {
		display: flex;
		flex-direction: column;
		gap: 12px;
		margin: 0 auto;
		max-width: 760px;
	}

	.faq-item {
		--accent: #5e9cff;
		padding: 0;
	}

	.faq-item summary {
		align-items: center;
		cursor: pointer;
		display: flex;
		gap: 14px;
		justify-content: space-between;
		list-style: none;
		padding: 18px 22px;
	}

	.faq-item summary::-webkit-details-marker {
		display: none;
	}

	.faq-q {
		font-size: 1rem;
		font-weight: 650;
	}

	.faq-chevron {
		border-bottom: 2px solid var(--ink-faint);
		border-right: 2px solid var(--ink-faint);
		flex-shrink: 0;
		height: 9px;
		transform: rotate(45deg);
		transition: transform 0.3s var(--ease);
		width: 9px;
	}

	.faq-item[open] .faq-chevron {
		transform: rotate(-135deg);
	}

	.faq-a {
		padding: 0 22px 20px;
	}

	.faq-a p {
		color: var(--ink-soft);
		font-size: 0.92rem;
		line-height: 1.65;
		margin: 0;
	}

	.faq-a :global(strong) {
		color: var(--ink);
	}
</style>
