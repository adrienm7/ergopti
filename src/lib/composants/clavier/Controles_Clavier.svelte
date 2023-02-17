<script>
	import hypertexte from '$lib/data/hypertexte.json';
	import { majClavier } from '$lib/js/clavier.js';

	export let emplacement;
	export let type;
	export let couche;
	export let couleur;
	export let plus;
	export let controles;

	function changerCouche(nouvelleCouche) {
		couche = nouvelleCouche;
		majClavier({
			emplacement: emplacement,
			data: hypertexte,
			config: {
				type: type,
				couche: couche,
				plus: plus,
				controles: controles
			}
		});
	}

	function toggleCouleur() {
		if (couleur == 'oui') {
			couleur = 'non';
		} else {
			couleur = 'oui';
		}
		document.getElementById(emplacement).dataset.couleur = couleur;
	}

	function toggleIso() {
		if (type == 'iso') {
			type = 'ergodox';
		} else {
			type = 'iso';
		}
		majClavier({
			emplacement: emplacement,
			data: hypertexte,
			config: {
				type: type,
				couche: couche,
				plus: plus,
				controles: controles
			}
		});
	}
	function togglePlus() {
		plus = !plus;
		majClavier({
			emplacement: emplacement,
			data: hypertexte,
			config: {
				type: type,
				couche: couche,
				plus: plus,
				controles: controles
			}
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
