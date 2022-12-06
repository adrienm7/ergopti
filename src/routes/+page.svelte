<script>
	import Nom from '../composants/Nom.svelte';
	import Clavier from '../composants/Clavier.svelte';
	import data from '$lib/data/hypertexte.json';
	import { majClavier } from '$lib/js/clavier.js';
	import { onMount } from 'svelte';

	let typeClavier = 'iso';
	let couche = 'Visuel';
	let couleur = 'oui';

	onMount(() => {
		majClavier({
			emplacement: 'clavier-presentation',
			data: data,
			typeClavier: typeClavier,
			couche: couche,
			couleur: couleur
		});
		majClavier({
			emplacement: 'clavier-freq',
			data: data,
			typeClavier: 'iso',
			couche: 'Visuel',
			couleur: 'freq'
		});
	});

	function changerCouche() {
		if (couche == 'Visuel') {
			couche = 'AltGr';
		} else {
			couche = 'Visuel';
		}
		majClavier({
			emplacement: 'clavier-presentation',
			data: data,
			typeClavier: typeClavier,
			couche: couche,
			couleur: couleur
		});
	}

	function toggleCouleur() {
		let emplacement = 'clavier-presentation';
		if (couleur == 'oui') {
			couleur = 'non';
		} else {
			couleur = 'oui';
		}
		document.getElementById(emplacement).dataset.couleur = couleur;
	}

	function toggleIso() {
		let emplacement = 'clavier-presentation';
		if (typeClavier == 'iso') {
			typeClavier = 'ergodox';
		} else {
			typeClavier = 'iso';
		}
		document.getElementById(emplacement).dataset.type = typeClavier;
		majClavier({
			emplacement: emplacement,
			data: data,
			typeClavier: typeClavier,
			couche: 'Visuel',
			couleur: 'non'
		});
	}
</script>

<h1>
	Disposition clavier<br />
	<span class="titre">
		<span class="titre-hyper">Hyper</span><span class="titre-texte">Texte</span>
	</span>
</h1>

<petit-espace />

<div class="btn-group">
	<button on:click={changerCouche}> Couche </button>
	<button on:click={toggleCouleur}>
		{couleur === 'oui' ? 'Couleur ➜ Noir et blanc' : 'Noir et blanc ➜ Couleur'}
	</button>
	<button on:click={toggleIso}>
		{typeClavier === 'iso' ? 'ISO ➜ Ergodox' : 'Ergodox ➜ ISO'}
	</button>
</div>
<mini-espace />
<bloc-clavier id="clavier-presentation">
	<Clavier />
</bloc-clavier>

<moyen-espace />

<bloc-clavier id="clavier-freq">
	<Clavier />
</bloc-clavier>

<moyen-espace />

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
