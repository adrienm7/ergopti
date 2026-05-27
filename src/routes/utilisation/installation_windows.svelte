<script>
	import { onMount } from 'svelte';
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import { getRelease } from '$lib/js/getGitHubRelease.js';

	/** @type {Awaited<ReturnType<typeof getRelease>>} */
	let release = null;
	// Extrait « 2.2.1 » depuis « v2.2.1 » ou « v2.2.1-dev.3 »
	$: tag = release?.tag?.replace(/^v/, "") ?? "…";
	$: urlKbdEdit = release?.url("Ergopti_windows.exe") ?? "#";

	onMount(async () => {
		release = await getRelease();
	});
</script>

<h2 id="windows">
	<i class="icon-windows purple" style="vertical-align:-0.05em"></i> Installation Windows
</h2>
<p>
	Le pilote ci-dessous a été réalisé à l'aide de <a
		class="link"
		href="https://www.kbdedit.com/"
		target="_blank">KbdEdit</a
	>. C'est un logiciel très complet qui permet de modifier des dispositions de clavier sur Windows.
	Il est en mesure de créer des pilotes pour Windows, et depuis peu pour Mac. Seul Linux n'est pas
	supporté.
</p>

<div class="download-buttons">
	<a href={urlKbdEdit} download={!!release}>
		<button disabled={!release}
			><i class="icon-windows" style="vertical-align:-0.05em"></i>
			Installateur KbdEdit d'Ergopti {tag}</button
		>
	</a>
</div>

<small-space></small-space>

<p>
	Il suffit d'exécuter le fichier <code>Ergopti_windows.exe</code> et de cliquer
	sur le bouton d'installation pour installer le pilote sur Windows. Ensuite, il est conseillé de redémarrer
	l'ordinateur pour être sûr que le pilote soit bien pris en compte.
</p>
<enhanced:img
	class="no-upscale"
	style="width: min(400px, 100%)!important;"
	src="$lib/images/windows_installation_1.jpg"
	alt="Screenshot d'installation du pilote KbdEdit"
/>

<div style="margin-top:15px"></div>

<p>
	Après l'installation, se rendre dans <code>Paramètres</code> >
	<code>Heure et langue</code> > <code>Langue et région</code> et cliquer sur le <code>…</code> de
	la langue installée (ici <code>Français (France)</code>) :
</p>
<enhanced:img
	src="$lib/images/windows_installation_2.jpg"
	alt="Screenshot 1/2 des paramètres Windows 11 pour changer sa disposition de clavier"
/>

<div style="margin-top:15px"></div>
<p>
	Cliquer ensuite sur <code>Ajouter un clavier</code> et sélectionner la version qui vient d'être ajoutée
	par l'installateur de KbdEdit :
</p>
<enhanced:img
	src="$lib/images/windows_installation_3.jpg"
	alt="Screenshot 2/2 des paramètres Windows 11 pour changer sa disposition de clavier"
/>
<p>
	Il est conseillé de supprimer tous les claviers de cette liste avant d'ajouter celui d'<Ergopti
	></Ergopti> et ensuite éventuellement rajouter vos autres claviers comme AZERTY. Cela permettra de
	l'avoir comme clavier par défaut, étant en première position de la liste.
</p>

<div style="margin-top:15px"></div>

<p>La disposition sera ensuite disponible dans le menu linguistique de la barre des tâches :</p>
<enhanced:img
	class="no-upscale"
	style="width: min(400px, 100%)!important;"
	src="$lib/images/windows_installation_4.jpg"
	alt="Screenshot du menu menu linguistique de la barre des tâches"
/>

<h3 id="windows-solutions">Résolution de problèmes connus</h3>
<p>
	Certains problèmes ont été rapportés avec le pilote Windows d'<Ergopti></Ergopti> dans quelques logiciels :
</p>
<ul>
	<li>
		<b>Microsoft Excel :</b> Taper un <kbd-output>+</kbd-output> avec <kbd>AltGr</kbd> +
		<kbd>P</kbd>
		cause des problèmes d'édition de la cellule : tout ce qui est tapé avant disparaît et est remplacé
		par un <kbd-output>+</kbd-output>.<br />➜ Ce problème se résout en utilisant le driver
		<a href="ergoptiplus" class="link"><ErgoptiPlus /></a>
		pour émuler la disposition et garantir que ce soit bien un symbole <kbd-output>+</kbd-output> qui
		soit envoyé et non un raccourci interne d'Excel qui interfère.
	</li>
</ul>
