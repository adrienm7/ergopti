<script>
	import Nom from './Nom.svelte';
	import Clavier from './Clavier.svelte';
	import data from '$lib/data/hypertexte.json';
	import { onMount } from 'svelte';

	function majClavier({ emplacement, typeClavier, couche, couleur }) {
		document.getElementById(emplacement).dataset.type = typeClavier;
		document.getElementById(emplacement).dataset.couleur = couleur;
		// document.getElementById(emplacement).style.setProperty('--frequence-max', mayzner['max']);
		for (let i = 1; i <= 5; i++) {
			for (let j = 0; j <= 15; j++) {
				const toucheClavier = document
					.getElementById(emplacement)
					.querySelector("[data-ligne='" + i + "'][data-colonne='" + j + "']");
				toucheClavier.dataset.touche = ''; // On nettoie le contenu de la touche
				const res = data[typeClavier].find((el) => (el.ligne == i) & (el.colonne == j));
				console.log(res);
				if (res !== undefined) {
					const touche = data.touches.find((el) => el.touche == res.touche);
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
					toucheClavier.style.setProperty('--frequence', mayzner[res.touche] / mayzner['max']);
					toucheClavier.style.setProperty(
						'--frequence-log',
						Math.log(mayzner[res.touche] / mayzner['max'])
					);
				}
			}
		}
	}

	let couleur = 'oui';
	let typeClavier = 'iso';

	onMount(() => {
		majClavier({
			emplacement: 'clavier1',
			typeClavier: 'iso',
			couche: 'Visuel',
			couleur: 'oui'
		});
		majClavier({
			emplacement: 'clavier-freq',
			typeClavier: 'iso',
			couche: 'Visuel',
			couleur: 'freq'
		});
	});

	function toggleCouleur() {
		let emplacement = 'clavier1';
		if (couleur == 'oui') {
			couleur = 'non';
		} else {
			couleur = 'oui';
		}
		document.getElementById(emplacement).dataset.couleur = couleur;
	}

	function toggleIso() {
		let emplacement = 'clavier1';
		if (typeClavier == 'iso') {
			typeClavier = 'ergodox';
		} else {
			typeClavier = 'iso';
		}
		document.getElementById(emplacement).dataset.type = typeClavier;
		majClavier({
			emplacement: emplacement,
			typeClavier: typeClavier,
			couche: 'Visuel',
			couleur: 'non'
		});
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
</script>

<h1>
	Disposition clavier<br />
	<span class="titre">
		<span class="titre-hyper">Hyper</span><span class="titre-texte">Texte</span>
	</span>
</h1>

<div style="height: 10vh;" />

<button on:click={toggleCouleur}>
	{couleur === 'oui' ? 'Couleur ➜ Noir et blanc' : 'Noir et blanc ➜ Couleur'}
</button>
<button on:click={toggleIso}>
	{typeClavier === 'iso' ? 'ISO ➜ Ergodox' : 'Ergodox ➜ ISO'}
</button>

<bloc-clavier id="clavier1">
	<Clavier />
</bloc-clavier>

<div style="height: 50px;" />
<bloc-clavier id="clavier-freq">
	<Clavier />
</bloc-clavier>

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

<h3>Optimisation pour l’utilisation à une main</h3>
<p>
	Le = a été dupliqué à gauche en accès direct. Cela permet de faire facilement les raccourcis sur
	excel comme = et Alt =. Normalement, le = se situe en AltGr + L.
</p>

<h3>Rangée des chiffres en accès direct</h3>
<p>
	Les chiffres sont en accès direct sur les dispositions QWERTY, mais pas en AZERTY. Chaque manière
	de faire a ses avantages, car en AZERTY les symboles sont alors en accès direct et plus facilement
	réalisables. En revanche, il devient alors compliqué d’écrire un chiffre ou un nombre en plein
	milieu de phrase, car cela nécessite de passer en Shift.
</p>
