<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<h2>Autocritiques</h2>

<h3>L’importance des compromis</h3>
<p>
	Il n’est évidemment pas possible de maximiser plusieurs paramètres en même temps. Par conséquent,
	certains choix ont dus être faits afin de maximiser chacun de ceux-ci sans trop sacrifier les
	autres.
</p>
<p>
	Par exemple, le <kbd>E</kbd> n’est pas sur l’index de la rangée de repos. Cela peut sembler
	étrange, tant son apparition est incontournable dans les textes (sauf dans le livre "La
	Disparition" qui arrive à ne jamais l’utiliser). Le <kbd>E</kbd> est la lettre la plus fréquente
	et de loin. Elle est si fréquente que sur le
	<a href="/#clavier_frequences">clavier affichant les touches les plus utilisées</a>
	de la page d’accueil, une transformation mathématique a été nécessaire pour que les fréquences relatives
	aux autres touches soient visibles et comparables.
</p>
<p>
	Pourtant, cette lettre n’a pas été placée sur l’index notamment afin de réduire les <SFB />s. En
	effet, si le
	<kbd>E</kbd>
	avait été sur l’index, alors les 6 touches tapées par ce doigt auraient possiblement générées des <SFB
	/>s avec le <kbd>E</kbd>. <kbd>E</kbd> s’associe avec quasiment toutes les lettres, donc ce serait
	une très mauvaise idée. Au contraire, la voyelle <kbd>U</kbd>
	ne s’associe pas avec beaucoup de lettres, elle est donc beaucoup plus pertinente à cet emplacement.
	D’autant que cet arrangement des voyelles permet alors de très bons roulements.
</p>

<h3>Points d’amélioration</h3>
<p>
	Bien que largement supérieure à certaines dispositions telles que l’AZERTY et même le BÉPO, <Nom
	/> est malheureusement encore loin d’être parfaite. En effet, la création d’une disposition est une
	affaire de compromis. Il est impossible de maximiser tous les aspects, car en maximisant le critère
	de distance aux touches, le <kbd>E</kbd> serait logiquement sur l’index, voire le pouce. Or, avoir
	cela engendrera beaucoup plus de <SFB />s, ce qui rendra impossible la maximisation de cet autre
	critère.
</p>
<p>
	En outre, parfois tous les emplacements sont mauvais pour une touche, et il faut choisir le moins
	pire. Par conséquent, <Nom /> a évidemment des défauts, dont voici les principaux :
</p>

<h4>Distances non optimales</h4>
<ul>
	<li><kbd>E</kbd> est sur le majeur et non sur l’index.</li>
	<p>
		Théoriquement, l’index est plus fort et devrait donc être l’endroit idéal pour la lettre <kbd
			>E</kbd
		> qui est de loin la lettre la plus fréquente, loin devant la deuxième lettre la plus fréquente de
		l’alphabet.
	</p>
</ul>

<h4>Quelques <SFB />s restants</h4>
<ul>
	<li>
		<kbd>SC</kbd> engendre beaucoup de <SFB />s, mais c’est à la moins pire combinaison (en
		fréquence d’apparition, <kbd-sortie>NC</kbd-sortie> > <kbd-sortie>CR</kbd-sortie> >
		<kbd-sortie>CT</kbd-sortie> > <kbd-sortie>SC</kbd-sortie>) et est en plus sur l’index qui est un
		doigt fort alors que le pire aurait été que cela soit sur l’annulaire ou l’auriculaire.
	</li>
	<li>
		<kbd>PT</kbd> : il est triste de se dire que pour quelqu’un utilisant une disposition o<span
			class="important">pt</span
		>imisée, l’écriture même de ce mot ne l’est pas…
	</li>
	<li>
		<kbd>EO</kbd> et <kbd>OE</kbd> : bien qu’inexistants en français, ces bigrammes sont relativement
		fréquents en anglais (people, does, etc.)
	</li>
	<li>
		<kbd>K</kbd> est assez loin sur clavier ISO, surtout pour l’anglais avec ses
		<kbd-sortie>SK</kbd-sortie>,
		<kbd-sortie>CK</kbd-sortie>, etc.
	</li>
</ul>
<p class="encadre">
	<b>Note :</b> Tous ces problèmes de <SFB></SFB>s sont résolus grâce à l’utilisation de <NomPlus
	></NomPlus>, y compris les <SFB></SFB>s encore plus rares.
	<i class="fa-duotone fa-face-smile"></i>
</p>

<h4>Alternance des mains non maximale</h4>
<ul>
	<li>
		<kbd>W</kbd> devrait théoriquement plutôt être du côté droit du clavier, car cette lettre est
		souvent précédée ou suivie d’une voyelle. Toutefois, la placer sur l’index gauche permet de
		mettre cette lettre sur un excellent emplacement tout en n’entraînant aucun <SFB /> supplémentaire
		sur l’index gauche. Ainsi, la distance des doigts aux touches s’en trouve diminuée, et des roulements
		très confortables pour l’anglais sont introduits, notamment avec le <kbd>O</kbd> (<kbd-sortie
			>WO</kbd-sortie
		>, <kbd-sortie>OW</kbd-sortie>).
	</li>
</ul>

<h4>Manque de caractères et non optimisation pour les autres langues</h4>
<p>
	<Nom></Nom> possède peu de touches mortes et de couches de symboles. En effet, la disposition ne se
	prétend pas être exhaustive en incorporant tous les alphabets des langues européennes comme le BÉPO,
	ou encore l’écriture phonétique comme Optimot. Ces couches n’intéressent que peu d’utilisateurs et
	occupent des emplacements du clavier très accessibles pour une utilisation très rare. En outre, <Nom
	></Nom> a été optimisée pour le français et l’anglais, et n’est pas la disposition la plus adaptée
	pour les autres langues.
</p>
<p>
	La philosophie derrière <Nom /> est de fournir une base de réflexion, mais pas nécessairement de promouvoir
	l’utilisation de la disposition « HyperTexte ». Rien ne vaut une disposition créée sur-mesure pour
	vos usages. Par exemple, si vous voulez écrire régulièrement en allemand, il serait judicieux de mettre
	la touche morte des trémats à un endroit plus accessible. De même, si vous écrivez souvent en espagnol,
	il faudra que vous trouviez un emplacement pour la lettre <kbd>Ñ</kbd>, etc. Sachant tout de même
	que <Nom></Nom> n’a pas été optimisée pour ces langages et n’est peut-être pas la disposition la plus
	adaptée si vous écrivez principalement dans celles-ci.
</p>
