<script>
	import { onMount } from 'svelte';

	import '$lib/css/normalize.css';
	import '$lib/css/global.css';
	import '$lib/css/typography.css';
	import '$lib/css/miscellaneous.css';
	import '$lib/css/clavier.css';

	import '$lib/js/clavier.js';
	import data from '$lib/data/hypertexte.json';

	export function genererClavier({ typeClavier, couche, couleur }) {
		// creating all cells
		for (let i = 1; i <= 5; i++) {
			const ligneClavier = document.createElement('bloc-ligne');
			ligneClavier.dataset.ligne = i;

			for (let j = 0; j <= 16; j++) {
				// Create a <td> element and a text node, make the text
				// node the contents of the <td>, and put the <td> at
				// the end of the table row
				var toucheClavier = document.createElement('bloc-touche');
				var res = data[typeClavier].find((el) => (el.ligne == i) & (el.colonne == j));
				if (res !== undefined) {
					var touche = data.touches.find((el) => el.touche == res.touche);
					console.log(touche);
					if (touche[couche] === '') {
						toucheClavier.innerHTML = '<div> </div>';
					} else {
						if (couche == 'Visuel') {
							if (touche.type == 'double') {
								toucheClavier.innerHTML =
									'<div>' +
									touche['Shift'].toUpperCase() +
									'<br/>' +
									touche['Primary'].toUpperCase() +
									'</div>';
							} else {
								toucheClavier.innerHTML = '<div>' + touche['Primary'].toUpperCase() + '</div>';
							}
						} else {
							toucheClavier.innerHTML = touche[couche].toUpperCase();
						}
					}
					toucheClavier.dataset.touche = res.touche;
					toucheClavier.dataset.colonne = j;
					toucheClavier.dataset.doigt = res.doigt;
					toucheClavier.dataset.main = res.main;
					toucheClavier.dataset.type = res.type;
					toucheClavier.style.setProperty('--taille', res.taille);
					if ((typeClavier == 'ergodox') & (j == 6)) {
						toucheClavier.style.marginRight = '5vw';
					}
					ligneClavier.appendChild(toucheClavier);
				}
			}

			// add the row to the end of the table body
			document.getElementById('bloc-clavier').appendChild(ligneClavier);
			document.getElementById('bloc-clavier').dataset.couleur = couleur;
		}
	}

	onMount(() => {
		genererClavier({
			typeClavier: 'iso',
			couche: 'Visuel',
			couleur: 'oui'
		});
	});

	const date = new Date().getFullYear();
</script>

<div id="page">
	<main>
		<slot />
	</main>

	<footer>
		<p>Copyright © {date} <strong>HyperTexte</strong></p>
	</footer>
</div>
