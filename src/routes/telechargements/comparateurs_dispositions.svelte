<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import { derniere_version } from '$lib/stores_infos.js';
	let version;
	derniere_version.subscribe((value) => {
		version = value;
	});
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
	<span>Version ISO : </span><a href="/dispositions/iso/hypertexte.v{version}.fr.iso.json" download
		><button>hypertexte.v{version}.fr.iso</button></a
	>
</div>
<mini-espace />
<div>
	<span>Version ISO+ : </span><a
		href="/dispositions/iso/hypertexte.v{version}.fr.iso+.json"
		download><button>hypertexte.v{version}.fr.iso+</button></a
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
		href="/dispositions/ergodox/hypertexte.v{version}.fr.ergodox.json"
		download><button>hypertexte.v{version}.fr.ergodox</button></a
	>
</div>

<h3>Ergo-L</h3>
<div>
	<span>Analyseur Ergo-L — Version à utiliser sur le site : </span><a
		href="/pilotes/kalamine/{version}/hypertexte_K.json"
		download><button>hypertexte_K.json</button></a
	>
</div>
<mini-espace />
<div>
	<span>Analyseur Ergo-L — Version théorique : </span><a
		href="/pilotes/kalamine/{version}/hypertexte.json"
		download><button>hypertexte.json</button></a
	>
	<p>
		Sur <a href="https://github.com/Nuclear-Squid/ergol">l’analyseur Ergo-L</a>, les touches
		assignées à chaque doigt diffèrent. La touche <kbd>À</kbd>
		par exemple est assignée à l’annulaire et non au majeur. Cela entraîne un <SFB />, car la touche
		<kbd>J</kbd>
		se retrouve sur le même doigt que la touche <kbd>E</kbd>. Le <kbd>J</kbd> doit normalement être
		sous le <kbd>U</kbd>. D’où la nécessité de la version K, qui corrige ce problème, mais place le
		<kbd>K</kbd>
		sous le <kbd>A</kbd> au lieu de sous le <kbd>U</kbd>.
	</p>
</div>
