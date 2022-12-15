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
			config: {
				type: typeClavier,
				couche: couche,
				couleur: couleur
			}
		});
		majClavier({
			emplacement: 'clavier-freq',
			data: data,
			config: {
				type: 'iso',
				couche: 'Visuel',
				couleur: 'freq'
			}
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
			config: {
				type: typeClavier,
				couche: couche,
				couleur: couleur
			}
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
			config: {
				type: typeClavier,
				couche: couche,
				couleur: couleur
			}
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

<p>
	<Nom /> est une disposition clavier destinée à taper majoritairement du français ainsi que de l’anglais.
	Elle se veut la plus optimale possible. Comment atteindre cet objectif ? C’est ce qui vous sera présenté
	sur cette page.
</p>

<h2>Genèse et raison des choix</h2>
<ul class="paragraphe">
	<li>Bépo, puis Optimot, puis Optim7 puis HyperTexte</li>
	<li>E sur le majeur et non l’index à cause des roulements et SFB</li>
	<li>Q puis P puis W sur l’index gauche</li>
	<li>Comment retenir les symboles en AltGr</li>
</ul>

<h2>Disposition clavier optimale</h2>

<h3>➀ Alternance des mains</h3>
<p>
	La première étape de la création d’<Nom /> a été d’essayer de classer les touches du clavier en deux
	groupes : main gauche et main droite. L’idée est d’essayer d’avoir le plus d’alternance des mains possibles
	lors de la frappe de texte: main droite, puis gauche, puis droite, etc. Pour cela, les voyelles ont
	toutes été placées d’un côté du clavier. les voyelles étant majoritairement précédées et suivies de
	consonnes. Cette idée n’est pas nouvelle, elle est déjà appliquée dans presque toutes les dispositions
	alternatives : Dvorak, BÉPO, etc. C’est du côté gauche, car sur clavier iso il y a moins de touches
	sur ce côté.
</p>

<h3>➁ Distance des doigts aux touches</h3>
<p>
	La deuxième étape est de placer les touches les plus souvent utilisées les plus proches possible
	des doigts. Les doigts sont censés toujours reposer sur la rangée de repos du clavier (la ligne du
	milieu). Il faut donc mettre sur cette rangée les lettres les plus utilisées. En outre, chaque
	doigt a une force différente. Ainsi, un pouce a plus de force qu’un index, qui a plus de force
	qu’un majeur, qui a plus de force qu’un annulaire, qui a plus de force qu’un auriculaire. D’où,
	les meilleurs emplacements sont ceux sur la rangée de repos, en partant de l’index à l’annulaire.
	Puis, la colonne au-dessus et en-dessous, en partant là aussi de l’index à l’annulaire.
</p>

<h3>➂ Minimisation des SFB</h3>

<h3>➃ Optimisation des roulements</h3>
<p>Un roulement est…</p>

<h4>Très bons digrammes</h4>
<ul class="paragraphe">
	<li>AI, IE, EU, AIE, IEU, OI, OU</li>
	<li>CH</li>
	<li>OW et WO</li>
	<li>YOU</li>
	<li>PL</li>
	<li>LD</li>
	<li>+=</li>
	<li>/* et */</li>
</ul>

<h4>Points d’amélioration</h4>

<ul class="paragraphe">
	<li>SC mais parce que c’est à la moins pire position</li>
	<li>PT</li>
	<li>EO et OE pour l’anglais</li>
	<li>K est assez loin, surtout pour l’anglais avec ses SK, CK, etc.</li>
</ul>

<h3>L’importance des compromis</h3>
<p>
	Il n’est évidemment pas possible de maximiser tous ces paramètres en même temps. Par conséquent,
	certains choix ont dus être faits.
</p>
<p>
	Notamment, le E n’est pas sur l’index de la rangée de repos. Ce qui est pourtant étrange, tant son
	apparition est fréquente dans les textes. C’est la lettre la plus fréquente et de loin. Pourtant,
	elle ne se trouve pas sur l’index notamment afin de réduire les SFB. Si le E avait été sur
	l’index, alors les 6 touches tapées par ce doigt auraient possiblement fait des SFB avec le E. E
	s’associe avec quasiment toutes les lettres, donc ce serait une très mauvaise idée. Au contraire,
	la voyelle U ne s’associe pas avec beaucoup de lettres, donc elle est bien mieux à cet
	emplacement. D’autant que cet arrangemement des voyelles permet alors de très bons roulements.
</p>

<h2>Autres choix de la disposition</h2>

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

<h2>Pour aller plus loin</h2>
<p>
	<Nom /> + permet d’avoir une disposition encore meilleure. Les roulements sont meilleurs et les doigts
	ont encore moins de distance à parcourir. Cependant, ces exxcellents résultats sont le fruit d’une
	fraude. En effet, ils nécessitent d’avoir un logiciel permettant de se faire des raccourcis personnalisés
	comme AutoHotkey. Il faudra aussi accepter d’apprendre certains enchaînements de touches.
</p>
