<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import {
		derniere_version,
		version_mineure_kla_iso,
		version_mineure_kla_iso_plus,
		version_mineure_kla_ergodox,
		version_mineure_kalamine
	} from '$lib/stores_infos.js';
	let version = derniere_version;

	let variante_hypertexte = 'hyper1dk';
</script>

<h2>Fichiers pour les comparateurs de dispositions</h2>

<h3>KLAnext</h3>
<p>
	Pour notamment les utiliser sur le site <a href="https://klanext.keyboard-design.com/"
		>https://klanext.keyboard-design.com/</a
	> et ses dérivés.
</p>
<mini-espace />
<div>
	<span>Version ISO : </span><a
		href="/dispositions/iso/hypertexte.v{version}.{version_mineure_kla_iso}.fr.iso.json"
		download><button>hypertexte.v{version}.{version_mineure_kla_iso}.fr.iso.json</button></a
	>
</div>
<mini-espace />
<div>
	<span>Version ISO+ : </span><a
		href="/dispositions/iso/hypertexte.v{version}.{version_mineure_kla_iso_plus}.fr.iso+.json"
		download><button>hypertexte.v{version}.{version_mineure_kla_iso_plus}.fr.iso+.json</button></a
	>
	<p>
		➜ Il n’y a de loin pas toutes les fonctionnalités de <NomPlus></NomPlus> dans ce fichier ISO+, car
		c’est impossible de les ajouter. Pour pouvoir les prendre en compte, comme l’utilisation de la touche
		<kbd>★</kbd>, il faudrait nécessairement modifier le corpus utilisé en entrée. Cependant, dans
		le même temps, cela va fausser toutes les comparaisons avec les autres dispositions. Par
		conséquent, la version ISO+ contient uniquement le déplacement des touches <kbd>Entrée</kbd>
		et
		<kbd>Shift</kbd>, mais cela améliore déjà sensiblement les scores.
	</p>
</div>
<mini-espace />
<div>
	<span>Version Ergodox : </span><a
		href="/dispositions/ergodox/hypertexte.v{version}.{version_mineure_kla_ergodox}.fr.ergodox.json"
		download><button>hypertexte.v{version}.{version_mineure_kla_ergodox}.fr.ergodox.json</button></a
	>
</div>

<h3>Ergo-L</h3>
<div>
	<div>
		<select bind:value={variante_hypertexte} style="height: 2rem">
			<option value="hyper1dk">1DFH</option>
			<option value="hypertxt_analyse">Standard — Analyse</option>
		</select>
	</div>
	<mini-espace />
	<span>Version pour l’analyseur Ergo-L : </span><a
		href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_hypertexte}.json"
		download><button>{variante_hypertexte}.json</button></a
	>
	<p>
		À noter que sur <a href="https://github.com/Nuclear-Squid/ergol">l’analyseur Ergo-L</a>, les
		touches assignées à chaque doigt diffèrent. Par exemple, la touche <kbd>À</kbd>
		est assignée à l’annulaire et non au majeur. Cela entraîne un <SFB />, car la touche
		<kbd>J</kbd>
		se retrouve sur le même doigt que la touche <kbd>E</kbd>. Le <kbd>J</kbd> doit normalement être
		sous le <kbd>U</kbd>. D’où la nécessité de déplacer le <kbd>K</kbd>, qui corrige ce problème,
		mais qui place alors le
		<kbd>K</kbd>
		sous le <kbd>A</kbd> au lieu de sous le <kbd>U</kbd>.
	</p>
	<p>
		En résumé, l’analyse Ergo-L ne sera pas tout à fait avec la vraie disposition, ceci à cause de
		ce déplacement du <kbd>K</kbd>. Toutefois, les résultats seront quand même très similaires,
		peut-être avec un tout petit plus de <SFB></SFB>s sur le <kbd>A</kbd> que dans la réalité, car
		il y a plus de
		<kbd-sortie>KA</kbd-sortie>
		que de <kbd-sortie>KU</kbd-sortie>.
	</p>
</div>
