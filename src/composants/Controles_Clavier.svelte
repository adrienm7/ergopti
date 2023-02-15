<script>
	import hypertexte from '$lib/data/hypertexte.json';
	import { majClavier } from '$lib/js/clavier.js';

	export let emplacement;
	export let type;
	export let couche;
	export let couleur;
	export let plus;

	function changerCouche(selected) {
		couche = selected;
		majClavier({
			emplacement: emplacement,
			data: hypertexte,
			config: {
				type: type,
				couche: couche,
				couleur: couleur,
				plus: plus
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
				couleur: couleur,
				plus: plus
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
				couleur: couleur,
				plus: plus
			}
		});
	}

	let options = [
		['Visuel', 'Visuel'],
		['Primary', 'Primary'],
		['Shift', 'Shift'],
		['AltGr', 'AltGr'],
		['Shift + AltGr', 'ShiftAltGr'],
		['Layer', 'layer'],
		['Touche À', 'à']
	];
	let selected = options[0]; // On actualise la valeur du select avec celle par défaut, cad "Visuel"
</script>

<div class="btn-group">
	<select bind:value={selected} on:change={() => changerCouche(selected[1])}>
		{#each options as value}<option {value}>{value[0]}</option>{/each}
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
</div>
