<script>
	import Bloc_Clavier from './Bloc_Clavier.svelte';
	// import Controles_Clavier from './Controles_Clavier.svelte';
	import data from '$lib/data/hypertexte.json';
	import { onMount } from 'svelte';

	export let emplacement;
	export let type;
	export let couche;
	export let couleur;
	export let plus;
	export let controles;

	onMount(() => {
		majClavier();
	});

	function majClavier() {
		majTouches();

		/* Presse les modificateurs de la couche active */
		activeModificateurs();

		if (controles === 'oui') {
			/* Il n’y a les touches pour changer de couche que quand il y a les boutons de contrôle */
			ajoutBoutonsChangerCouche();
		}
	}

	function majTouches() {
		for (let i = 1; i <= 5; i++) {
			for (let j = 0; j <= 15; j++) {
				// Suppression des event listeners sur la touche
				const toucheClavier0 = document
					.getElementById(emplacement)
					.querySelector("bloc-touche[data-ligne='" + i + "'][data-colonne='" + j + "']");
				const toucheClavier = toucheClavier0.cloneNode(true);
				toucheClavier0.parentNode.replaceChild(toucheClavier, toucheClavier0);

				// Nettoyage de la touche
				toucheClavier.dataset.touche = ''; // Suppression du contenu de la touche
				toucheClavier.classList.remove('touche-active'); // Suppression de la classe css pour les touches pressées

				// Récupération de ce qui doit être affiché sur la touche
				const res = data[type].find((el) => (el.ligne == i) & (el.colonne == j));
				// console.log(res);

				if (res !== undefined) {
					const contenuTouche = data.touches.find((el) => el.touche == res.touche);
					toucheClavier.dataset.plus = 'non';
					if (contenuTouche[couche] === '') {
						toucheClavier.innerHTML = '<div> <div>';
					} else {
						if (couche === 'Visuel') {
							if (contenuTouche.type === 'double') {
								if (res.touche === '"') {
									// Cas particulier de la touche « " »
									toucheClavier.innerHTML =
										'<div>' +
										contenuTouche['Shift'] +
										'<br/>' +
										contenuTouche['Primary'] +
										'</div>';
								} else {
									// Toutes les autres touches "doubles"
									toucheClavier.innerHTML =
										'<div>' +
										contenuTouche['AltGr'] +
										'<br/>' +
										contenuTouche['Primary'] +
										'</div>';
								}
							} else {
								// Cas où la touche n’est pas double
								if (plus === 'oui') {
									// Cas où la touche n’est pas double et + est activé
									if (contenuTouche['Primary' + '+'] !== undefined) {
										// Si la couche + existe
										toucheClavier.innerHTML = '<div>' + contenuTouche['Primary' + '+'] + '</div>';
										toucheClavier.dataset.plus = 'oui';
									} else {
										toucheClavier.innerHTML = '<div>' + contenuTouche['Primary'] + '</div>';
									}
								} else {
									toucheClavier.innerHTML = '<div>' + contenuTouche['Primary'] + '</div>';
								}
							}
						} else {
							// Toutes les couches autres que "Visuel"
							if (plus === 'oui') {
								if (contenuTouche[couche + '+'] !== undefined) {
									toucheClavier.innerHTML = '<div>' + contenuTouche[couche + '+'] + '</div>';
									toucheClavier.dataset.plus = 'oui';
								} else {
									toucheClavier.innerHTML = '<div>' + contenuTouche[couche] + '</div>';
								}
							} else {
								toucheClavier.innerHTML = '<div>' + contenuTouche[couche] + '</div>';
							}
						}
					}

					// On ajoute des infos dans les data attributes de la touche
					toucheClavier.dataset['touche'] = res.touche;
					toucheClavier.dataset.colonne = j;
					toucheClavier.dataset.doigt = res.doigt;
					toucheClavier.dataset.main = res.main;
					toucheClavier.dataset.type = contenuTouche.type;
					toucheClavier.style.setProperty('--taille', res.taille);
					toucheClavier.style.setProperty('--frequence', mayzner[res.touche] / mayzner['max']);
					toucheClavier.style.setProperty(
						'--frequence-log',
						Math.log(mayzner[res.touche] / mayzner['max'])
					);
				}
			}
		}
	}

	function activeModificateurs() {
		let lShift = document.getElementById(emplacement).querySelector("[data-touche='LShift']");
		let rShift = document.getElementById(emplacement).querySelector("[data-touche='RShift']");
		let lCtrl = document.getElementById(emplacement).querySelector("[data-touche='LCtrl']");
		let rCtrl = document.getElementById(emplacement).querySelector("[data-touche='RCtrl']");
		let altGr = document.getElementById(emplacement).querySelector("[data-touche='RAlt']");
		let aGrave = document.getElementById(emplacement).querySelector("[data-touche='à']");
		let space = document.getElementById(emplacement).querySelector("[data-touche='Space']");

		if ((couche === 'Shift') & (lShift !== null)) {
			lShift.classList.add('touche-active');
		}
		if ((couche === 'Shift') & (rShift !== null)) {
			rShift.classList.add('touche-active');
		}
		if ((couche === 'Ctrl') & (lCtrl !== null)) {
			lCtrl.classList.add('touche-active');
		}
		if ((couche === 'Ctrl') & (rCtrl !== null)) {
			rCtrl.classList.add('touche-active');
		}
		if ((couche === 'AltGr') & (altGr !== null)) {
			altGr.classList.add('touche-active');
		}
		if ((couche == 'ShiftAltGr') & (lShift !== null)) {
			lShift.classList.add('touche-active');
		}
		if ((couche === 'ShiftAltGr') & (rShift !== null)) {
			rShift.classList.add('touche-active');
		}
		if ((couche === 'ShiftAltGr') & (altGr !== null)) {
			altGr.classList.add('touche-active');
		}
		if ((couche === 'À') & (aGrave !== null)) {
			aGrave.classList.add('touche-active');
		}
		if ((couche === 'Layer') & (space !== null)) {
			space.classList.add('touche-active');
		}
	}

	function ajoutBoutonsChangerCouche() {
		let emplacementClavier = document.getElementById(emplacement);
		let toucheRAlt = emplacementClavier.querySelector("bloc-touche[data-touche='RAlt']");
		let toucheLShift = emplacementClavier.querySelector("bloc-touche[data-touche='LShift']");
		let toucheRShift = emplacementClavier.querySelector("bloc-touche[data-touche='RShift']");
		let toucheLCtrl = emplacementClavier.querySelector("bloc-touche[data-touche='LCtrl']");
		let toucheRCtrl = emplacementClavier.querySelector("bloc-touche[data-touche='RCtrl']");
		let toucheSpace = emplacementClavier.querySelector("bloc-touche[data-touche='Space']");
		let toucheA = emplacementClavier.querySelector("bloc-touche[data-touche='à']");

		// On ajoute une action au clic sur chacune des touches modificatrices
		for (let toucheModificatrice of [
			toucheRAlt,
			toucheLShift,
			toucheRShift,
			toucheLCtrl,
			toucheRCtrl
		]) {
			if (toucheModificatrice !== null) {
				toucheModificatrice.addEventListener('click', function () {
					changerCouche(toucheModificatrice);
				});
			}
		}

		// Les boutons de touches modificatrices À et Space ne sont ajoutées que si + est activé
		if (plus === 'oui') {
			for (let toucheModificatrice of [toucheSpace, toucheA]) {
				if (toucheModificatrice !== null) {
					toucheModificatrice.addEventListener('click', function () {
						changerCouche(toucheModificatrice);
					});
				}
			}
		}
	}

	function changerCouche(toucheModificatrice) {
		let touchePressee = toucheModificatrice.dataset.touche;
		let coucheActuelle = document.getElementById(emplacement).dataset.couche;
		let nouvelleCouche = coucheActuelle;

		// Touche pressée = AltGr
		if ((touchePressee === 'RAlt') & (coucheActuelle === 'AltGr')) {
			nouvelleCouche = 'Visuel';
		} else if ((touchePressee === 'RAlt') & (coucheActuelle === 'Shift')) {
			nouvelleCouche = 'ShiftAltGr';
		} else if ((touchePressee === 'RAlt') & (coucheActuelle === 'ShiftAltGr')) {
			nouvelleCouche = 'Shift';
		} else if (touchePressee === 'RAlt') {
			nouvelleCouche = 'AltGr';
		}

		// Touche pressée = Shift
		if (
			((touchePressee === 'LShift') | (touchePressee === 'RShift')) &
			(coucheActuelle === 'AltGr')
		) {
			nouvelleCouche = 'ShiftAltGr';
		} else if (
			((touchePressee === 'LShift') | (touchePressee === 'RShift')) &
			(coucheActuelle === 'Shift')
		) {
			nouvelleCouche = 'Visuel';
		} else if (
			((touchePressee === 'LShift') | (touchePressee === 'RShift')) &
			(coucheActuelle === 'ShiftAltGr')
		) {
			nouvelleCouche = 'AltGr';
		} else if (
			((touchePressee === 'LShift') | (touchePressee === 'RShift')) &
			(coucheActuelle === 'À')
		) {
			nouvelleCouche = 'Shift';
		} else if ((touchePressee === 'LShift') | (touchePressee === 'RShift')) {
			nouvelleCouche = 'Shift';
		}

		// Touche pressée = Ctrl
		if (((touchePressee === 'LCtrl') | (touchePressee === 'RCtrl')) & (coucheActuelle !== 'Ctrl')) {
			nouvelleCouche = 'Ctrl';
		} else if ((touchePressee === 'LCtrl') | (touchePressee === 'RCtrl')) {
			nouvelleCouche = 'Visuel';
		}

		// Touche pressée = Space (pour accéder au Layer)
		if ((touchePressee === 'Space') & (coucheActuelle === 'Layer')) {
			nouvelleCouche = 'Visuel';
		} else if (touchePressee === 'Space') {
			nouvelleCouche = 'Layer';
		}

		// Touche pressée = À
		if ((touchePressee === 'à') & (coucheActuelle === 'À')) {
			nouvelleCouche = 'Visuel';
		} else if (touchePressee === 'à') {
			nouvelleCouche = 'À';
		}

		// Une fois que la nouvelle couche est déterminée, on actualise le clavier
		couche = nouvelleCouche;
		majClavier();
	}

	function toggleCouche(nouvelleCouche) {
		couche = nouvelleCouche;
		majClavier();
	}

	function toggleCouleur() {
		if (couleur === 'oui') {
			couleur = 'non';
		} else {
			couleur = 'oui';
		}
	}

	function toggleType() {
		if (type === 'iso') {
			type = 'ergodox';
		} else {
			type = 'iso';
		}
		majClavier();
	}

	function togglePlus() {
		if (plus === 'oui') {
			plus = 'non';
			if (couche === 'À' || couche === 'Layer') {
				// Dans le cas où l’on est sur une couche spécifique à HyperTexte+, on change la couche pour une qui existe dans la version standard
				couche = 'Visuel';
			}
		} else {
			plus = 'oui';
		}
		majClavier();
	}

	function taperTexte(texte, vitesse, disparition_anciennes_touches) {
		let emplacementClavier = document.getElementById(emplacement);

		// Nettoyage des touches actives
		const touchesActives = emplacementClavier.querySelectorAll('.touche-active');
		[].forEach.call(touchesActives, function (el) {
			el.classList.remove('touche-active');
		});

		// let texte = 'test';
		function writeNext(texte, i) {
			let nouvelleLettre = texte.charAt(i);
			emplacementClavier
				.querySelector("bloc-touche[data-touche='" + nouvelleLettre + "']")
				.classList.add('touche-active');

			if (disparition_anciennes_touches) {
				if (i == texte.length) {
					emplacementClavier
						.querySelector("bloc-touche[data-touche='" + texte.charAt(i - 1) + "']")
						.classList.remove('touche-active');
					return;
				}

				if (i !== 0) {
					let ancienneLettre = texte.charAt(i - 1);
					emplacementClavier
						.querySelector("bloc-touche[data-touche='" + ancienneLettre + "']")
						.classList.remove('touche-active');
				}
			}

			setTimeout(function () {
				writeNext(texte, i + 1);
			}, vitesse);
		}

		writeNext(texte, 0);
	}

	var mayzner = {
		max: 12.49,
		a: 8.04,
		b: 1.48,
		c: 3.34,
		d: 3.82,
		e: 12.49,
		f: 2.4,
		g: 1.87,
		h: 5.05,
		i: 7.57,
		j: 0.16,
		k: 0.54,
		l: 4.07,
		m: 2.51,
		n: 7.23,
		o: 7.64,
		p: 2.14,
		q: 0.12,
		r: 6.28,
		s: 6.51,
		t: 9.28,
		u: 2.73,
		v: 1.05,
		w: 1.68,
		x: 0.23,
		y: 1.66,
		z: 0.09
	};

	let couches_standard = [
		['Visuel', 'Visuel'],
		['➀ Primaire', 'Primary'],
		['➁ Shift', 'Shift'],
		['➂ AltGr', 'AltGr'],
		['➃ Shift + AltGr', 'ShiftAltGr'],
		['Ctrl', 'Ctrl']
	];
	let couches_plus = couches_standard.concat([
		['★ Layer', 'Layer'],
		['★ Touche À', 'À']
	]);

	let roulements_voyelles = ['ai', 'ie', 'eu', 'io', 'ou', 'oi', 'au', 'aie', 'ieu', 'you'];
	let roulements_consonnes = ['ch', 'pl', 'ld'];
	let texte;
</script>

<ensemble-clavier
	id={emplacement}
	data-type={type}
	data-couche={couche}
	data-couleur={couleur}
	data-plus={plus}
	data-controles={controles}
	class="center"
>
	<Bloc_Clavier />
	{#if controles === 'oui'}
		<mini-espace />
		<!-- <Controles_Clavier {emplacement} {type} {couche} {couleur} {plus} {controles} /> -->
		<controles-clavier class="btn-group">
			<button on:click={toggleCouleur}>
				{couleur === 'oui' ? 'Couleur ➜ Noir et blanc' : 'Noir et blanc ➜ Couleur'}
			</button>
			<button on:click={toggleType}>
				{type === 'iso' ? 'ISO ➜ Ergodox' : 'Ergodox ➜ ISO'}
			</button>
			<button on:click={togglePlus}>
				{plus === 'oui' ? 'Plus ➜ Standard' : 'Standard ➜ Plus'}
			</button>
			{#if plus === 'non'}
				<select bind:value={couche} on:change={() => toggleCouche(couche)}>
					{#each couches_standard as value}<option value={value[1]}>{value[0]}</option>{/each}
				</select>
			{/if}
			{#if plus === 'oui'}
				<select bind:value={couche} on:change={() => toggleCouche(couche)}>
					{#each couches_plus as value}<option value={value[1]}>{value[0]}</option>{/each}
				</select>
			{/if}
		</controles-clavier>
	{/if}
	{#if controles === 'roulements'}
		<controles-clavier class="btn-group">
			<select bind:value={texte} on:change={() => taperTexte(texte, 250, false)}>
				{#each roulements_voyelles as value}<option {value}>{value.toUpperCase()}</option>{/each}
			</select>
			<select bind:value={texte} on:change={() => taperTexte(texte, 250, false)}>
				{#each roulements_consonnes as value}<option {value}>{value.toUpperCase()}</option>{/each}
			</select>
		</controles-clavier>
	{/if}
</ensemble-clavier>

<style>
	.center {
		display: flex;
		flex-direction: column;
		justify-content: space-around;
	}
</style>
