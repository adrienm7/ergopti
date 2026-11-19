<script>
	import Ergopti from '#lib/components/Ergopti.svelte';
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
	import SFB from '#lib/components/SFB.svelte';

	import { version } from '#lib/stores_infos.js';
	import { asset } from '$app/paths';
	import { getLatestVersion } from '#lib/js/getVersions.js';
	let versionValue,
		version_mineure_kla_iso,
		version_mineure_kla_iso_plus,
		version_mineure_kla_ergodox,
		version_mineure_kalamine_1dk,
		version_mineure_kalamine_analyse;
	version.subscribe((value) => {
		versionValue = value;
		version_mineure_kla_iso = getLatestVersion('kla_iso', versionValue);
		version_mineure_kla_iso_plus = getLatestVersion('kla_iso_plus', versionValue);
		version_mineure_kla_ergodox = getLatestVersion('kla_ergodox', versionValue);
		version_mineure_kalamine_1dk = '2.1.2'; // getLatestVersion('kalamine_1dk', versionValue);
		version_mineure_kalamine_analyse = '2.1.2'; // getLatestVersion('kalamine_analyse', versionValue);
	});

	let version_mineure_kalamine;
	let nom_variante_kalamine;
	let suffixe_nom_variante_kalamine;
	$: {
		if (variante_kalamine == 'standard') {
			version_mineure_kalamine = version_mineure_kalamine_analyse;
			nom_variante_kalamine = 'ergopti';
			suffixe_nom_variante_kalamine = '_analyse';
		} else {
			version_mineure_kalamine = version_mineure_kalamine_1dk;
			nom_variante_kalamine = 'ergo_1dk';
			suffixe_nom_variante_kalamine = '';
		}
	}
	let variante_kalamine = 'standard';
</script>

<section>
	<h2>Fichiers pour les comparateurs de dispositions</h2>

	<h3>KLAnext</h3>
	<p>
		Pour notamment les utiliser sur le site <a
			class="link"
			href="https://klanext.keyboard-design.com/"
			target="_blank">https://klanext.keyboard-design.com/</a
		> et ses dérivés.
	</p>
	<tiny-space></tiny-space>
	<p class="download">
		Version ISO :&nbsp;<a
			class="button-link"
			href={asset(`layouts/kla_iso/ergopti.v${version_mineure_kla_iso}.fr.iso.json`)}
			download>ergopti.v{version_mineure_kla_iso}.fr.iso.json</a
		>
	</p>
	<tiny-space></tiny-space>
	<p class="download">
		Version ISO+ :&nbsp;<a
			class="button-link"
			href={asset(`layouts/kla_iso/ergopti.v${version_mineure_kla_iso_plus}.fr.iso+.json`)}
			download>ergopti.v{version_mineure_kla_iso_plus}.fr.iso+.json</a
		>
	</p>
	<p>
		➜ Il n’y a de loin pas toutes les fonctionnalités d’<ErgoptiPlus></ErgoptiPlus> dans ce fichier ISO+,
		car c’est impossible de les ajouter. Pour pouvoir les prendre en compte, comme l’utilisation de la
		touche
		<kbd>★</kbd>, il faudrait nécessairement modifier le corpus utilisé en entrée. Cependant, dans
		le même temps, cela va fausser toutes les comparaisons avec les autres dispositions. Par
		conséquent, la version ISO+ contient uniquement le déplacement des touches <kbd>Entrée</kbd>
		et
		<kbd>Shift</kbd>, mais cela améliore déjà sensiblement les scores.
	</p>
	<tiny-space></tiny-space>
	<p class="download">
		Version Ergodox :&nbsp;<a
			class="button-link"
			href={asset(`layouts/kla_ergodox/ergopti.v${version_mineure_kla_ergodox}.fr.ergodox.json`)}
			download>ergopti.v{version_mineure_kla_ergodox}.fr.ergodox.json</a
		>
	</p>

	<h3>Ergo‑L</h3>
	<div>
		<select
			bind:value={variante_kalamine}
			style="height: 2rem"
			aria-label="Variante Ergo‑L à télécharger"
		>
			<option value="1dk" selected>1DFH</option>
			<option value="standard">Standard — Analyse</option>
		</select>
	</div>
	<tiny-space></tiny-space>
	<p class="download">
		Version pour l’analyseur Ergo‑L :&nbsp;<a
			class="button-link"
			href={asset(
				`ergopti_plus/old/kalamine/${variante_kalamine}/${nom_variante_kalamine}_v${version_mineure_kalamine}${suffixe_nom_variante_kalamine}.toml`
			)}
			download
			>{nom_variante_kalamine}_v{version_mineure_kalamine}{suffixe_nom_variante_kalamine}.toml</a
		>
	</p>
	<p>
		À noter que sur <a href="https://github.com/Nuclear-Squid/ergol" target="_blank" class="link"
			>l’analyseur Ergo‑L</a
		>, les touches assignées à chaque doigt diffèrent. Par exemple, la touche <kbd>À</kbd>
		est assignée à l’annulaire et non au majeur. Cela entraîne un <SFB />, car la touche
		<kbd>J</kbd>
		se retrouve sur le même doigt que la touche <kbd>E</kbd>. Le <kbd>J</kbd> doit normalement être
		sous le <kbd>U</kbd>. D’où la nécessité de déplacer le <kbd>K</kbd>, qui corrige ce problème,
		mais qui place alors le
		<kbd>K</kbd>
		sous le <kbd>A</kbd> au lieu de sous le <kbd>U</kbd>.
	</p>
	<p>
		En résumé, l’analyse Ergo‑L ne sera pas tout à fait avec la vraie disposition, ceci à cause du
		déplacement du <kbd>K</kbd>. Toutefois, les résultats seront quand même très similaires,
		peut-être avec un tout petit plus de <SFB></SFB>s sur le <kbd>A</kbd> que dans la réalité, car
		il y a plus de
		<kbd-output>KA</kbd-output>
		que de <kbd-output>KU</kbd-output>.
	</p>
</section>

<style>
	/* A download line was a plain block: it keeps the full width, the text
	   line height and no paragraph spacing of the prose column. */
	.download {
		line-height: inherit;
		margin: 0;
		max-width: none;
		text-align: inherit;
	}
</style>
