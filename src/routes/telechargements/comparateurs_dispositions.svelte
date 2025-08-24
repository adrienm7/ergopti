<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import { version } from '$lib/stores_infos.js';
	import { getLatestVersion } from '$lib/js/getVersions.js';
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
		version_mineure_kalamine_1dk = getLatestVersion('kalamine_1dk', versionValue);
		version_mineure_kalamine_analyse = getLatestVersion('kalamine_analyse', versionValue);
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

<h2>Fichiers pour les comparateurs de dispositions</h2>

<h3>KLAnext</h3>
<p>
	Pour notamment les utiliser sur le site <a
		class="link"
		href="https://klanext.keyboard-design.com/">https://klanext.keyboard-design.com/</a
	> et ses dérivés.
</p>
<mini-espace />
<div>
	<span>Version ISO : </span><a
		href="/dispositions/iso/ergopti.v{version_mineure_kla_iso}.fr.iso.json"
		download><button>ergopti.v{version_mineure_kla_iso}.fr.iso.json</button></a
	>
</div>
<mini-espace />
<div>
	<span>Version ISO+ : </span><a
		href="/dispositions/iso/ergopti.v{version_mineure_kla_iso_plus}.fr.iso+.json"
		download><button>ergopti.v{version_mineure_kla_iso_plus}.fr.iso+.json</button></a
	>
	<p>
		➜ Il n’y a de loin pas toutes les fonctionnalités de <ErgoptiPlus></ErgoptiPlus> dans ce fichier
		ISO+, car c’est impossible de les ajouter. Pour pouvoir les prendre en compte, comme l’utilisation
		de la touche
		<kbd>★</kbd>, il faudrait nécessairement modifier le corpus utilisé en entrée. Cependant, dans
		le même temps, cela va fausser toutes les comparaisons avec les autres dispositions. Par
		conséquent, la version ISO+ contient uniquement le déplacement des touches <kbd>Entrée</kbd>
		et
		<kbd>Shift</kbd>, mais cela améliore déjà sensiblement les scores.
	</p>
</div>
<mini-espace />
<div>
	<span>Version Ergodox : </span><a
		href="/dispositions/ergodox/ergopti.v{version_mineure_kla_ergodox}.fr.ergodox.json"
		download><button>ergopti.v{version_mineure_kla_ergodox}.fr.ergodox.json</button></a
	>
</div>

<h3>Ergo-L</h3>
<div>
	<div>
		<select bind:value={variante_kalamine} style="height: 2rem">
			<option value="1dk" selected>1DFH</option>
			<option value="standard">Standard — Analyse</option>
		</select>
	</div>
	<mini-espace />
	<span>Version pour l’analyseur Ergo-L : </span><a
		href="/pilotes/kalamine/{variante_kalamine}/{nom_variante_kalamine}_v{version_mineure_kalamine}{suffixe_nom_variante_kalamine}.toml"
		download
		><button
			>{nom_variante_kalamine}_v{version_mineure_kalamine}{suffixe_nom_variante_kalamine}.toml</button
		></a
	>
	<p>
		À noter que sur <a class="link" href="https://github.com/Nuclear-Squid/ergol"
			>l’analyseur Ergo-L</a
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
		En résumé, l’analyse Ergo-L ne sera pas tout à fait avec la vraie disposition, ceci à cause du
		déplacement du <kbd>K</kbd>. Toutefois, les résultats seront quand même très similaires,
		peut-être avec un tout petit plus de <SFB></SFB>s sur le <kbd>A</kbd> que dans la réalité, car
		il y a plus de
		<kbd-sortie>KA</kbd-sortie>
		que de <kbd-sortie>KU</kbd-sortie>.
	</p>
</div>
