<!-- src/routes/editeur/+page.svelte -->

<!--
==============================================================================
MODULE: Layout Editor Page
DESCRIPTION:
The website tab of the unified layout editor. It frames the shared editor
page served as-is from static/ergopti_plus/_shared/ui/layout_editor/, the
same code ErgoptiPlus mounts in its layout manager window, so the site and
the app can never diverge. Files open with the browser's file picker and
save as downloads; nothing leaves the visitor's computer.
==============================================================================
-->

<script>
	import { asset, resolve } from '$app/paths';
	import PageWrapper from '../PageWrapper.svelte';

	/** Height of the framed editor; it scrolls inside the frame beyond that. */
	const EDITOR_HEIGHT_PX = 1400;

	const editorSrc = asset('ergopti_plus/_shared/ui/layout_editor/index.html') + '?lang=fr';
</script>

<svelte:head>
	<title>Éditeur de disposition</title>
	<meta
		name="description"
		content="Créer ou modifier sa disposition de clavier, l’enregistrer en TOML Ergopti et l’exporter"
	/>
</svelte:head>

<PageWrapper>
	<svelte:fragment slot="introduction">
		<bloc-introduction>
			<h1>Éditeur de disposition</h1>
			<p>
				Configurez votre propre disposition : couches, touches mortes, modificateurs, raccourcis et
				couche de navigation. Ouvrez ou enregistrez le fichier source Ergopti (TOML), importez un
				<code>.keylayout</code> et téléchargez ce que le générateur sait déjà produire. L’éditeur fonctionne
				entièrement dans votre navigateur : aucun fichier n’est envoyé.
			</p>
			<ol class="layout-editor-steps">
				<li>
					<strong>Partir de</strong> : « Nouvelle » propose une disposition vierge, QWERTY, AZERTY, Bépo,
					Ergo-L ou Ergopti, à modifier.
				</li>
				<li>
					<strong>Exporter pour chaque système</strong> : le paquet macOS (<code>.bundle</code>),
					les fichiers XKB de Linux et le <code>.klc</code> de Windows se téléchargent ici. Le
					pilote
					<code>.dll</code> de Windows et son installateur <code>.exe</code> ne se construisent pas
					dans un navigateur : ils sortent de l’outil du dépôt (<code
						>node tools/kbd-dll.cjs build</code
					>).
				</li>
				<li>
					<strong>Installer ou émuler</strong> : dans
					<a href={resolve('/ergopti-plus')}>ErgoptiPlus</a>, le menu « Disposition clavier » ouvre
					le même éditeur, qui sait installer la disposition sur le système ou l’émuler sans rien
					installer (sans droit administrateur).
					<a href={resolve('/ergopti-plus') + '#ep-telecharger'}>Télécharger ErgoptiPlus</a>.
				</li>
			</ol>
		</bloc-introduction>
	</svelte:fragment>

	<iframe
		class="layout-editor-frame"
		title="Éditeur de disposition Ergopti"
		src={editorSrc}
		style="height:{EDITOR_HEIGHT_PX}px"
	></iframe>
</PageWrapper>

<style>
	.layout-editor-frame {
		border: 0;
		border-radius: 8px;
		display: block;
		width: 100%;
	}
</style>
