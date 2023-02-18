<script>
	import hypertexte from '$lib/data/hypertexte.json';
	import { majClavier } from '$lib/js/clavier.js';

	export let emplacement;
	let type;
	let couche;
	let couleur;
	let plus;

	function changerCouche(nouvelleValeur) {
		document.getElementById(emplacement).dataset.couche = nouvelleValeur;
		couche = nouvelleValeur;
		document.getElementById(emplacement).querySelector('select').value = nouvelleValeur;
		majClavier({
			emplacement: emplacement,
			data: hypertexte
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
		couleur = nouvelleValeur;
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
		type = nouvelleValeur;
		majClavier({
			emplacement: emplacement,
			data: hypertexte
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
		plus = nouvelleValeur;
		majClavier({
			emplacement: emplacement,
			data: hypertexte
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
	<button on:click={togglePlus} data-button="plus">
		{plus === 'oui' ? 'Plus ➜ Standard' : 'Standard ➜ Plus'}
	</button>
	<button on:click={toggleCouleur} data-button="couleur">
		{couleur === 'oui' ? 'Couleur ➜ Noir et blanc' : 'Noir et blanc ➜ Couleur'}
	</button>
	<button on:click={toggleIso} data-button="type">
		{type === 'iso' ? 'ISO ➜ Ergodox' : 'Ergodox ➜ ISO'}
	</button>
</controles-clavier>
