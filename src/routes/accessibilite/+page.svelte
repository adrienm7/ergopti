<!-- src/routes/accessibilite/+page.svelte -->

<!--
==============================================================================
MODULE: Accessibility Statement
DESCRIPTION:
The public accessibility statement of the site, Ergopti Studio and Ergopti+:
the conformance target, how it is checked, the settings the site offers, the
known gaps and how to report a barrier. The gaps listed here follow the audit
in docs/audits/accessibility/; update both together.

FEATURES & RATIONALE:
1. Language: the statement reads in the Ergopti+ pages' language (the
   maintainer decided on 2026-11-21 to translate it into English through the
   same t() dictionary). Its content says its own language (WCAG 3.1.2): the
   site's chrome around it stays French.
==============================================================================
-->

<script>
	import { onMount } from 'svelte';
	import Ergopti from '#lib/components/Ergopti.svelte';
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
	import PageWrapper from '#lib/components/PageWrapper.svelte';
	import { discordLink } from '#lib/stores_infos.js';
	import LangToggle from '../ergopti-plus/LangToggle.svelte';
	import { i18n, t, restoreLang } from '../ergopti-plus/i18n.svelte.js';

	onMount(() => {
		restoreLang();
	});

	/** Open the settings dialog of the header. */
	function openSettings() {
		document.getElementById('a11y-settings-button').click();
	}
</script>

<svelte:head>
	<title>{t('Déclaration d’accessibilité — Ergopti')}</title>
	<meta
		name="description"
		content={t(
			'Accessibilité du site Ergopti, d’Ergopti Studio et d’Ergopti+ : objectif WCAG 2.2 AA, réglages proposés, limites connues et contact'
		)}
	/>
</svelte:head>

<PageWrapper>
	<svelte:fragment slot="introduction">
		<bloc-introduction>
			<section class="main" lang={i18n.lang}>
				<h1>{t('Déclaration d’accessibilité')}</h1>
				<hr class="margin-h1" />
				<LangToggle />
			</section>
		</bloc-introduction>
	</svelte:fragment>

	<section lang={i18n.lang}>
		<h2>{t('Objectif')}</h2>
		<p>
			{t('Le site')}
			<Ergopti></Ergopti>{t(', Ergopti Studio et')}
			<ErgoptiPlus></ErgoptiPlus>
			{t(
				'doivent pouvoir être utilisés par tout le monde. Ils doivent fonctionner au clavier seul, avec un lecteur d’écran, avec un zoom important, sans animations ou avec une police adaptée. L’objectif est la conformité au niveau'
			)}
			<strong>AA</strong>
			{t('des')}
			<a href="https://www.w3.org/TR/WCAG22/" class="link" lang="en"
				>Web Content Accessibility Guidelines 2.2</a
			>
			{t('(WCAG 2.2), et au niveau AAA quand cela coûte peu.')}
		</p>
		<p>
			<strong>{t('État actuel : partiellement conforme.')}</strong>
			{t(
				'Les travaux ont commencé le 16 novembre 2026 ; les limites connues sont listées plus bas.'
			)}
		</p>
	</section>

	<section lang={i18n.lang}>
		<h2>{t('Comment c’est vérifié')}</h2>
		<p>
			{t(
				'Chaque page du site et chaque page d’Ergopti Studio est analysée automatiquement à chaque modification, en thème clair et en thème sombre, avec l’outil'
			)}
			<span lang="en">axe-core</span>{t(
				'. Le nombre de défauts détectés ne peut que baisser : une modification qui en ajoute un est refusée. Chaque page est aussi relue avec un texte agrandi à 200 % et l’espacement élargi. Aucun texte ne doit y être coupé, en recouvrir un autre ou passer sous l’en-tête. Aucun paragraphe n’est justifié et aucune ligne ne dépasse 80 caractères. L’analyse automatique ne détecte qu’une partie des problèmes : des vérifications manuelles (lecteurs d’écran, navigation au clavier, zoom) la complètent.'
			)}
		</p>
	</section>

	<section lang={i18n.lang}>
		<h2>{t('Réglages proposés')}</h2>
		<p>
			{t('Le bouton d’accessibilité en haut de chaque page')}
			<button type="button" class="link-button" onclick={openSettings}
				>{t('ouvre les réglages d’accessibilité')}</button
			>{t('. Ils s’appliquent au site et à Ergopti Studio, et ce navigateur les retient :')}
		</p>
		<ul>
			<li>
				{t(
					'réduire les animations et les défilements (le réglage « réduire les animations » du système est aussi respecté) ;'
				)}
			</li>
			<li>
				{t('une police très lisible,')}
				<span lang="en">Atkinson Hyperlegible</span>{t(
					', conçue par le Braille Institute pour les personnes malvoyantes, ou une police pensée pour les personnes dyslexiques,'
				)}
				<span lang="en">OpenDyslexic</span>{t(' ;')}
			</li>
			<li>{t('un texte plus grand, jusqu’à 200 % ;')}</li>
			<li>{t('un espacement élargi des lettres, des mots et des lignes ;')}</li>
			<li>{t('des lignes de texte plus courtes, et tout le texte aligné à gauche ;')}</li>
			<li>{t('un contraste élevé ;')}</li>
			<li>
				{t(
					'des couleurs que les personnes daltoniennes distinguent, sur les claviers dessinés et les démonstrations.'
				)}
			</li>
		</ul>
		<p>
			{t(
				'Toutes les pages ont aussi un lien « Aller au contenu », visible au premier appui sur la touche Tab.'
			)}
		</p>
	</section>

	<section lang={i18n.lang}>
		<h2>{t('Limites connues')}</h2>
		<ul>
			<li>
				{t(
					'Les graphiques et cartes de chaleur du Comparer et des benchmarks n’ont pas encore tous leurs chiffres sous forme de tableau.'
				)}
			</li>
			<li>
				{t(
					'Les dessins de clavier du site se lisent comme des tableaux, mais ceux d’Ergopti Studio ne nomment pas encore toutes leurs touches pour les lecteurs d’écran.'
				)}
			</li>
			<li>
				{t('La démonstration animée de la page d’')}<ErgoptiPlus></ErgoptiPlus>
				{t(
					'défile seule et n’a pas encore de bouton pause ; le réglage « réduire les animations » l’arrête.'
				)}
			</li>
			<li>
				{t('Les fenêtres d’')}<ErgoptiPlus></ErgoptiPlus>
				{t(
					'(menus, réglages, info-bulles) n’ont pas encore été vérifiées avec les lecteurs d’écran de Windows, macOS et Linux.'
				)}
			</li>
			<li>
				{t('Les vidéos de démonstration n’ont pas encore de sous-titres ni de transcription.')}
			</li>
		</ul>
	</section>

	<section lang={i18n.lang}>
		<h2>{t('Signaler un problème')}</h2>
		<p>
			{t('Si une partie du site, d’Ergopti Studio ou d’')}<ErgoptiPlus></ErgoptiPlus>
			{t(
				'vous est difficile ou impossible à utiliser, merci de le signaler : c’est ce qui permet de le corriger. Décrivez la page, ce que vous cherchiez à faire et, si possible, votre navigateur et votre outil d’assistance.'
			)}
		</p>
		<ul>
			<li>
				{t('en créant une')}
				<em lang="en">Issue</em>
				{t('sur')}
				<a href="https://github.com/adrienm7/ergopti/issues" target="_blank" class="link"
					>{t('la page GitHub du projet')}</a
				>{t(' ;')}
			</li>
			<li>
				{t('ou sur le')}
				<a href={discordLink} class="link">{t('serveur Discord BÉPO | Ergodis')}</a>{t(
					', dans le canal d’'
				)}<Ergopti></Ergopti>{t('.')}
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
