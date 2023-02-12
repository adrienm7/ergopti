<script>
	import Nom from '../composants/Nom.svelte';
	import Nom_Plus from '../composants/Nom_Plus.svelte';
	import Clavier from '../composants/Clavier.svelte';
	import hypertexte from '$lib/data/hypertexte.json';
	import { majClavier } from '$lib/js/clavier.js';
	import { onMount } from 'svelte';

	let typeClavier = 'iso';
	let couche = 'Visuel';
	let couleur = 'oui';
	let plus = false;

	onMount(() => {
		majClavier({
			emplacement: 'clavier-presentation',
			data: hypertexte,
			config: {
				type: typeClavier,
				couche: couche,
				couleur: couleur,
				plus: plus
			}
		});
		majClavier({
			emplacement: 'clavier-freq',
			data: hypertexte,
			config: {
				type: 'iso',
				couche: 'Visuel',
				couleur: 'freq',
				plus: false
			}
		});
	});

	function changerCouche(selected) {
		couche = selected;
		majClavier({
			emplacement: 'clavier-presentation',
			data: hypertexte,
			config: {
				type: typeClavier,
				couche: couche,
				couleur: couleur,
				plus: plus
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
		majClavier({
			emplacement: emplacement,
			data: hypertexte,
			config: {
				type: typeClavier,
				couche: couche,
				couleur: couleur,
				plus: plus
			}
		});
	}
	function togglePlus() {
		let emplacement = 'clavier-presentation';
		plus = !plus;
		majClavier({
			emplacement: emplacement,
			data: hypertexte,
			config: {
				type: typeClavier,
				couche: couche,
				couleur: couleur,
				plus: plus
			}
		});
	}

	let selected = 'Visuel';
	let options = ['Visuel', 'Primary', 'Shift', 'AltGr', 'ShiftAltGr', 'layer'];
</script>

<div class="contenu">
	<div class="fullheight">
		<div>
			<h1 class="titre">
				Disposition clavier<br /><span class="hyper">—&nbsp;Hyper</span><span class="texte"
					>Texte&nbsp;—</span
				>
			</h1>
		</div>

		<bloc-clavier id="clavier-presentation">
			<Clavier />
		</bloc-clavier>

		<div class="btn-group">
			<select bind:value={selected} on:change={() => changerCouche(selected)}>
				{#each options as value}<option {value}>{value}</option>{/each}
			</select>
			<button on:click={togglePlus}>
				{plus === true ? 'Plus ➜ Normal' : 'Normal ➜ Plus'}
			</button>
			<button on:click={toggleCouleur}>
				{couleur === 'oui' ? 'Couleur ➜ Noir et blanc' : 'Noir et blanc ➜ Couleur'}
			</button>
			<button on:click={toggleIso}>
				{typeClavier === 'iso' ? 'ISO ➜ Ergodox' : 'Ergodox ➜ ISO'}
			</button>
		</div>
	</div>

	<mini-espace />

	<p class="important">
		<Nom /> est une disposition clavier optimisée. Elle est destinée à taper majoritairement du français
		ainsi que de l’anglais. Elle se veut la plus <span class="hyper">optimale</span> possible. Comment
		atteindre cet objectif ? C’est ce qui vous sera présenté sur cette page.
	</p>

	<h2>Genèse et raison des choix</h2>
	<p>
		Les améliorations d’Optimot par rapport au Bépo sont vraiment significatives. Les tests sont
		sans appel et montrent notamment une nette diminution des digrammes à un doigt. Après beaucoup
		d’hésitation à passer du Bépo à Optimot, j’ai voulu d’abord être certain que l’apprentissage de
		cette nouvelle disposition serait le dernier. C’est pourquoi j’ai décidé de regarder par
		moi-même si Optimot pouvait éventuellement encore être améliorée avant de faire mon choix.
	</p>
	<ul class="paragraphe">
		<li>Bépo, puis Optimot, puis Optim7 puis HyperTexte</li>
		<li>E sur le majeur et non l’index à cause des roulements et SFB</li>
		<li>Q puis P puis W sur l’index gauche</li>
		<li>Comment retenir les symboles en AltGr</li>
	</ul>
	<h3>Utilisation de la couche AltGr</h3>
	<p>
		N’ayant nullement besoin de tous les caractères exotiques des touches mortes Bépo/Optimot, j’en
		ai supprimé la majeure partie. Cela me laisse assez de place pour avoir à la fois les
		ponctuations avec espace insécable automatique en Shift et à la fois les ponctuations seules en
		AltGr pour la programmation notamment. Cela fait que je n’ai plus grande utilité des espaces
		insécables et espaces fines insécables. Celles-ci sont donc déplacées à un autre endroit pour me
		permettre d’avoir le tiret en Shift+Espace qui est beaucoup plus utile. L’underscore reste en
		AltGr+Espace.
	</p>

	<h3>Chiffres en accès direct</h3>
	<p>
		Les chiffres sont en accès direct sur les dispositions QWERTY, mais pas en AZERTY. Chaque
		manière de faire a ses avantages, car en AZERTY les symboles sont alors en accès direct et plus
		facilement réalisables. En revanche, il devient alors compliqué d’écrire un chiffre ou un nombre
		en plein milieu de phrase, car cela nécessite de passer en Shift.
	</p>
	<p>
		De plus, une autre de mes modifications est le passage des chiffres en accès direct, car
		maintenir Shift enfoncé pour écrire rapidement un nombre n’est vraiment pas pratique. J’en
		profite pour déplacer les caractères qui étaient auparavant en accès direct sur la rangée des
		chiffres. Ils se retrouvent en AltGr sur les 3 rangées du milieu pour ne pas avoir à trop bouger
		les doigts.
	</p>

	<h2>Disposition clavier optimisée</h2>

	<h3>➀ Alternance des mains</h3>
	<p>
		La première étape dans la création d’<Nom /> a été de classer les touches du clavier en deux groupes
		: main gauche et main droite. L’objectif de cela est d’essayer d’avoir le plus d’alternance des mains
		possible lors de la frappe de texte : main droite, puis gauche, puis droite, etc. Cette alternance
		des mains permet de ne pas surutiliser l’une des deux mains en tapant la majorité du texte avec au
		détriment de l’autre main. Cela permet aussi de gagner légèrement en confort et vitesse car pendant
		qu’une main tape, l’autre peut se replacer en position de repos et se préparer à taper la touche
		suivante.
	</p>
	<p>
		Pour optimiser ce critère, les voyelles ont toutes été placées d’un côté du clavier. Celles-ci
		étant majoritairement précédées et suivies de consonnes, cela amène immédiatement une grande
		alternance des mains. À noter que cette idée est loin d’être nouvelle, car elle est déjà
		appliquée dans presque toutes les dispositions alternatives : Dvorak, BÉPO, etc.
	</p>
	<p>
		Dans le cas d’<Nom />, les voyelles ont été placées sur le côté gauche. La raison est que sur la
		plupart des claviers (i.e ceux qui sont non matriciels) il y a moins de touches sur ce côté. Le
		côté droit a en effet trois colonnes de touches pour l’auriculaire alors que l’auriculaire
		gauche n’en a qu’une. Ces nombreux emplacements sont précieux, surtout pour les langues ayant
		besoin de caractères supplémentaires comme les accents en français.
	</p>

	<h3>➁ Distance des doigts aux touches</h3>
	<p>
		La deuxième étape dans la création de la disposition a été de placer les touches les plus
		souvent utilisées les plus proches possible des doigts. Les doigts sont effectivement toujours
		censés reposer sur la rangée de repos du clavier (la ligne du milieu). Il est donc logique de
		chercher à placer sur cette rangée les lettres les plus utilisées pour réduire les déplacements
		des doigts aux touches.
	</p>
	<p>
		En outre, chaque doigt a une force différente. Ainsi, un pouce a plus de force qu’un index, qui
		a plus de force qu’un majeur, qui a plus de force qu’un annulaire, qui a plus de force qu’un
		auriculaire. Par conséquent, les meilleurs emplacements sont ceux sur la rangée de repos, en
		partant de l’index à l’annulaire. Puis, les meilleurs emplacements seront sur les colonnes
		au-dessus et en-dessous de la rangée de repos, en partant là encore de l’index à l’annulaire. La
		rangée des chiffres est donc la moins accessible, c’est pour cela que laisser le <kbd>É</kbd> sur
		cette ligne comme en AZERTY est une très mauvaise idée, car cette lettre est beaucoup utilisée en
		français.
	</p>

	<moyen-espace />
</div>
<bloc-clavier id="clavier-freq">
	<Clavier />
</bloc-clavier>
<div class="contenu">
	<grand-espace />

	<h3>➂ Minimisation des SFB</h3>

	<h3>➃ Optimisation des roulements</h3>
	<p>
		Pour moi, un "roulement" désigne plutôt un déplacement sur deux doigts consécutifs et jamais à
		plus d’une rangée d’écart. Il y peu d’informations sur le sujet en ligne ; un roulement a
		probablement une définition plus large que la mienne, mais alors dans ce cas le côté "qui roule"
		est selon moi perdu. À la limite si c’est de l’index à l’auriculaire, mais pas de l’index à
		l’annulaire par exemple. En conclusion, un roulement est pour moi le ST du Bépo (idéalement, car
		mouvement horizontal), sinon le LS du Bépo, mais pas le GL ni le TR du Bépo. La disposition
		Optim7 a été construite avec pour contrainte principale de permettre de réaliser les digrammes
		consonne-consonne les plus courants grâce à des roulements, de préférence sur des doigts
		consécutifs dans un mouvement horizontal.
	</p>

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

	<h2>L’importance des compromis</h2>
	<p>
		Il n’est évidemment pas possible de maximiser tous ces paramètres en même temps. Par conséquent,
		certains choix ont dus être faits.
	</p>
	<p>
		Notamment, le E n’est pas sur l’index de la rangée de repos. Ce qui est pourtant étrange, tant
		son apparition est fréquente dans les textes. C’est la lettre la plus fréquente et de loin.
		Pourtant, elle ne se trouve pas sur l’index notamment afin de réduire les SFB. Si le E avait été
		sur l’index, alors les 6 touches tapées par ce doigt auraient possiblement fait des SFB avec le
		E. E s’associe avec quasiment toutes les lettres, donc ce serait une très mauvaise idée. Au
		contraire, la voyelle U ne s’associe pas avec beaucoup de lettres, donc elle est bien mieux à
		cet emplacement. D’autant que cet arrangemement des voyelles permet alors de très bons
		roulements.
	</p>

	<h3>Points d’amélioration</h3>

	<ul class="paragraphe">
		<li>SC mais parce que c’est à la moins pire position</li>
		<li>PT</li>
		<li>EO et OE pour l’anglais</li>
		<li>K est assez loin, surtout pour l’anglais avec ses SK, CK, etc.</li>
	</ul>

	<h2>Autres choix de la disposition</h2>

	<h3>Optimisation pour l’utilisation à une main</h3>
	<p>
		Le <kbd>=</kbd> a été dupliqué à gauche en accès direct. Cela permet de faire facilement les
		raccourcis sur Excel comme <kbd>=</kbd> et <kbd>Alt</kbd> + <kbd>=</kbd>. Normalement, le
		<kbd>=</kbd>
		se situe en <kbd>AltGr</kbd> + <kbd>L</kbd>.
	</p>

	<h2>★★★ Pour aller plus loin ★★★</h2>
	<p>
		<Nom_Plus /> permet d’avoir une disposition encore meilleure. Les roulements sont meilleurs et les
		doigts ont encore moins de distance à parcourir. Cependant, ces excellents résultats sont le fruit
		d’une fraude. En effet, ils nécessitent d’avoir un logiciel permettant de se faire des raccourcis
		personnalisés comme AutoHotkey. Il faudra aussi accepter d’apprendre certains enchaînements de touches.
	</p>
</div>
