<script>
	import Nom from './Nom.svelte';

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

	let couleur = 'oui';

	function handleClick() {
		count += 1;
		genererClavier({
			typeClavier: 'iso',
			couche: 'Visuel',
			couleur: 'non'
		});
	}

	function toggleCouleur() {
		if (couleur == 'oui') {
			couleur = 'non';
		} else {
			couleur = 'oui';
		}
		document.getElementById('bloc-clavier').dataset.couleur = couleur;
	}
</script>

<h1>
	Disposition clavier<br />
	<span class="titre">
		<span class="titre-hyper">Hyper</span><span class="titre-texte">Texte</span>
	</span>
</h1>

<div style="height: 10vh;" />
<button on:click={toggleCouleur}>
	{couleur === 'oui' ? 'En couleur' : 'En noir et blanc'}
</button>
<bloc-clavier id="bloc-clavier" />
<div style="height: 50px;" />

<p><Nom /> est une disposition clavier destinée à taper du français en de l’anglais.</p>

<h2>Disposition clavier optimale</h2>

<h3>➀ Alternance des mains</h3>
<p>
	La première étape de la création d’<Nom /> a été d’essayer de classer les touches du clavier en deux
	groupes : main gauche et main droite. Pour cela, les voyelles ont toutes été placées du côté gauche,
	les voyelles étant majoritairement précédées et suivies de consonnes. Cette idée n’est pas nouvelle,
	elle est déjà appliquée dans presque toutes les dispositions alternatives : Dvorak, BÉPO, etc.
</p>

<h3>➁ Distance des doigts aux touches</h3>
<p>
	La deuxième étape est de placer les touches les plus souvent utilisées sur la rangée de repos du
	clavier (la ligne du milieu).
</p>

<h3>➂ Minimisation des SFB</h3>

<h2>Pour aller plus loin</h2>

<p>
	<Nom /> + permet d’avoir une disposition encore meilleure. Le seul prix à payer est qu’il faut accepter
	d’apprendre certains enchaînements de touches.
</p>
