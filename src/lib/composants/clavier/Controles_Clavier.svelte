<script>
	import hypertexte from '$lib/data/hypertexte.json';
	import { majClavier } from '$lib/js/clavier.js';

	export let emplacement;
	export let type;
	export let couche;
	export let couleur;
	export let plus;

	let controles = true;

	// let type = document.getElementById(emplacement).dataset.type;
	// let couche = document.getElementById(emplacement).dataset.couche;
	// let couleur = document.getElementById(emplacement).dataset.couleur;
	// let plus = document.getElementById(emplacement).dataset.plus;

	function changerCouche(nouvelleValeur) {
		document.getElementById(emplacement).dataset.couche = nouvelleValeur;
		majClavier({
			emplacement: emplacement,
			data: hypertexte,
			controles: controles
		});
	}

	function toggleCouleur() {
		let ancienneValeur = document.getElementById(emplacement).dataset.couleur;
		let nouvelleValeur = ancienneValeur;
		if (ancienneValeur == 'oui') {
			nouvelleValeur = 'non';
		} else {
			nouvelleValeur = 'oui';
		}
		document.getElementById(emplacement).dataset.couleur = nouvelleValeur;
	}

	function toggleIso() {
		let ancienneValeur = document.getElementById(emplacement).dataset.type;
		let nouvelleValeur = ancienneValeur;
		if (ancienneValeur == 'iso') {
			nouvelleValeur = 'ergodox';
		} else {
			nouvelleValeur = 'iso';
		}
		document.getElementById(emplacement).dataset.type = nouvelleValeur;
		majClavier({
			emplacement: emplacement,
			data: hypertexte,
			controles: controles
		});
	}
	function togglePlus() {
		let ancienneValeur = document.getElementById(emplacement).dataset.plus;
		let nouvelleValeur = ancienneValeur;

		if (ancienneValeur == 'oui') {
			nouvelleValeur = 'non';
		} else {
			nouvelleValeur = 'oui';
		}

		document.getElementById(emplacement).dataset.plus = nouvelleValeur;
		majClavier({
			emplacement: emplacement,
			data: hypertexte,
			controles: controles
		});
	}

	// let options = ['Visuel', 'Primary', 'Shift', 'AltGr', 'ShiftAltGr', 'layer', 'à'];
	let options = [
		['Visuel', 'Visuel'],
		['Primary', 'Primary'],
		['Shift', 'Shift'],
		['AltGr', 'AltGr'],
		['Shift + AltGr', 'ShiftAltGr'],
		['Layer', 'layer'],
		['Touche À', 'à']
	];
</script>

<controles-clavier class="btn-group">
	<select bind:value={couche} on:change={() => changerCouche(couche)}>
		{#each options as value}<option value={value[1]}>{value[0]}</option>{/each}
	</select>
	<button on:click={togglePlus}>
		{plus === true ? 'Plus ➜ Standard' : 'Standard ➜ Plus'}
	</button>
	<button on:click={toggleCouleur}>
		{couleur === 'oui' ? 'Couleur ➜ Noir et blanc' : 'Noir et blanc ➜ Couleur'}
	</button>
	<button on:click={toggleIso}>
		{type === 'iso' ? 'ISO ➜ Ergodox' : 'Ergodox ➜ ISO'}
	</button>
</controles-clavier>
