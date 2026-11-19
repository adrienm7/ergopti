<!-- src/routes/accessibilite/+page.svelte -->

<!--
==============================================================================
MODULE: Accessibility Statement
DESCRIPTION:
The public accessibility statement of the site, Ergopti Studio and Ergopti+:
the conformance target, how it is checked, the settings the site offers, the
known gaps and how to report a barrier. The gaps listed here follow the audit
in docs/audits/accessibility/; update both together.
==============================================================================
-->

<script>
	import Ergopti from '#lib/components/Ergopti.svelte';
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
	import PageWrapper from '#lib/components/PageWrapper.svelte';
	import { discordLink } from '#lib/stores_infos.js';

	/** Open the settings dialog of the header. */
	function openSettings() {
		document.getElementById('a11y-settings-button').click();
	}
</script>

<svelte:head>
	<title>Déclaration d’accessibilité — Ergopti</title>
	<meta
		name="description"
		content="Accessibilité du site Ergopti, d’Ergopti Studio et d’Ergopti+ : objectif WCAG 2.2 AA, réglages proposés, limites connues et contact"
	/>
</svelte:head>

<PageWrapper>
	<svelte:fragment slot="introduction">
		<bloc-introduction>
			<section class="main">
				<h1>Déclaration d’accessibilité</h1>
				<hr class="margin-h1" />
			</section>
		</bloc-introduction>
	</svelte:fragment>

	<section>
		<h2>Objectif</h2>
		<p>
			Le site <Ergopti></Ergopti>, Ergopti Studio et <ErgoptiPlus></ErgoptiPlus> doivent pouvoir être
			utilisés par tout le monde : au clavier seul, avec un lecteur d’écran, avec un zoom important,
			sans animations ou avec une police adaptée. L’objectif est la conformité au niveau
			<strong>AA</strong> des
			<a href="https://www.w3.org/TR/WCAG22/" class="link" lang="en"
				>Web Content Accessibility Guidelines 2.2</a
			>
			(WCAG 2.2), et au niveau AAA quand cela coûte peu.
		</p>
		<p>
			<strong>État actuel : partiellement conforme.</strong> Les travaux ont commencé le 16 novembre
			2026 ; les limites connues sont listées plus bas.
		</p>
	</section>

	<section>
		<h2>Comment c’est vérifié</h2>
		<p>
			Chaque page du site et chaque page d’Ergopti Studio est analysée automatiquement à chaque
			modification, en thème clair et en thème sombre, avec l’outil
			<span lang="en">axe-core</span>. Le nombre de défauts détectés ne peut que baisser : une
			modification qui en ajoute un est refusée. Chaque page est aussi relue avec un texte agrandi à
			200 % et l’espacement élargi. Aucun texte ne doit y être coupé, en recouvrir un autre ou
			passer sous l’en-tête. Aucun paragraphe n’est justifié et aucune ligne ne dépasse 80
			caractères. L’analyse automatique ne détecte qu’une partie des problèmes : des vérifications
			manuelles (lecteurs d’écran, navigation au clavier, zoom) la complètent.
		</p>
	</section>

	<section>
		<h2>Réglages proposés</h2>
		<p>
			Le bouton d’accessibilité en haut de chaque page
			<button type="button" class="link-button" onclick={openSettings}
				>ouvre les réglages d’accessibilité</button
			>. Ils s’appliquent au site et à Ergopti Studio, et ce navigateur les retient :
		</p>
		<ul>
			<li>
				réduire les animations et les défilements (le réglage « réduire les animations » du système
				est aussi respecté) ;
			</li>
			<li>
				une police très lisible, <span lang="en">Atkinson Hyperlegible</span>, conçue par le Braille
				Institute pour les personnes malvoyantes, ou une police pensée pour les personnes
				dyslexiques, <span lang="en">OpenDyslexic</span> ;
			</li>
			<li>un texte plus grand, jusqu’à 200 % ;</li>
			<li>un espacement élargi des lettres, des mots et des lignes ;</li>
			<li>des lignes de texte plus courtes, et tout le texte aligné à gauche ;</li>
			<li>un contraste élevé ;</li>
			<li>
				des couleurs que les personnes daltoniennes distinguent, sur les claviers dessinés et les
				démonstrations.
			</li>
		</ul>
		<p>
			Toutes les pages ont aussi un lien « Aller au contenu », visible au premier appui sur la
			touche Tab.
		</p>
	</section>

	<section>
		<h2>Limites connues</h2>
		<ul>
			<li>
				Les graphiques et cartes de chaleur du Comparer et des benchmarks n’ont pas encore tous
				leurs chiffres sous forme de tableau.
			</li>
			<li>
				Les dessins de clavier du site se lisent comme des tableaux, mais ceux d’Ergopti Studio ne
				nomment pas encore toutes leurs touches pour les lecteurs d’écran.
			</li>
			<li>
				La démonstration animée de la page d’<ErgoptiPlus></ErgoptiPlus> défile seule et n’a pas encore
				de bouton pause ; le réglage « réduire les animations » l’arrête.
			</li>
			<li>
				Les fenêtres d’<ErgoptiPlus></ErgoptiPlus> (menus, réglages, info-bulles) n’ont pas encore été
				vérifiées avec les lecteurs d’écran de Windows, macOS et Linux.
			</li>
			<li>Les vidéos de démonstration n’ont pas encore de sous-titres ni de transcription.</li>
			<li>
				L’ancienne page d’<ErgoptiPlus></ErgoptiPlus> n’est plus mise à jour et garde ses défauts.
			</li>
		</ul>
	</section>

	<section>
		<h2>Signaler un problème</h2>
		<p>
			Si une partie du site, d’Ergopti Studio ou d’<ErgoptiPlus></ErgoptiPlus> vous est difficile ou
			impossible à utiliser, merci de le signaler : c’est ce qui permet de le corriger. Décrivez la page,
			ce que vous cherchiez à faire et, si possible, votre navigateur et votre outil d’assistance.
		</p>
		<ul>
			<li>
				en créant une <em lang="en">Issue</em> sur
				<a href="https://github.com/adrienm7/ergopti/issues" target="_blank" class="link"
					>la page GitHub du projet</a
				> ;
			</li>
			<li>
				ou sur le <a href={discordLink} class="link">serveur Discord BÉPO | Ergodis</a>, dans le
				canal d’<Ergopti></Ergopti>.
			</li>
		</ul>
	</section>
</PageWrapper>

<style>
	.link-button {
		background: none;
		border: none;
		color: inherit;
		cursor: pointer;
		font: inherit;
		padding: 0;
		text-decoration: underline;
	}
</style>
