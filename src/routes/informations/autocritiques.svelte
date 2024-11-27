<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<h2>Autocritiques</h2>

<h3>L’importance des compromis</h3>
<p>
	Il est évident qu’il n’est pas possible de maximiser plusieurs paramètres simultanément.
	Bien que largement supérieure à de nombreuses dispositions telles que l’AZERTY et même le BÉPO, <Nom
	/> est donc malheureusement loin d’être parfaite. En effet, la création d’une disposition est une
	affaire de compromis. Des choix ont dû être effectués pour maximiser chacun des critères d’évaluation sans trop
	compromettre les autres.
</p>
<p>
	Par exemple, le <kbd>E</kbd> n’est pas sur l’index de la rangée de repos. Cela peut sembler
	étrange, tant son apparition est incontournable dans les textes (sauf dans le livre <i>La
	Disparition</i> qui arrive l’exploit de ne jamais l’utiliser). Le <kbd>E</kbd> est la lettre la plus fréquente
	et de loin. Elle est si fréquente que sur le
	<a href="/#clavier_frequences">clavier affichant les touches les plus utilisées</a>
	de la page d’accueil, une transformation mathématique a été nécessaire pour que les fréquences relatives
	aux autres touches soient visibles et comparables.
</p>
<p>
	Pourtant, cette lettre n’a pas été placée sur l’index, notamment afin de réduire les <SFB />s. En
	effet, si le <kbd>E</kbd> avait été sur l’index, alors les 6 touches tapées par ce doigt auraient possiblement générées des <SFB
	/>s avec le <kbd>E</kbd>. <kbd>E</kbd> s’associe avec quasiment toutes les lettres, donc ce serait
	une très mauvaise idée. Au contraire, la voyelle <kbd>U</kbd>
	ne s’associe pas avec beaucoup de lettres, elle est donc beaucoup plus pertinente à cet emplacement.
	D’autant que cet arrangement des voyelles permet alors de très bons roulements.
</p>
<p>
	En outre, parfois tous les emplacements sont mauvais pour une touche, et il faut choisir le moins
	pire. Par conséquent, <Nom /> a évidemment des défauts, dont les principaux sont recensés ici.
</p>


<h3>Distances non optimales</h3>
<ul>
	<li>
		<kbd>E</kbd> est sur le majeur et non sur l’index. Théoriquement, l’index est plus fort et
		devrait donc être l’endroit idéal pour la lettre <kbd>E</kbd> qui est de loin la lettre la plus fréquente,
		loin devant la deuxième lettre la plus fréquente de l’alphabet.
	</li>
	<li>
		Le <kbd>K</kbd>, bien que très rare en français et peu fréquent en anglais, est à une position
		assez lointaine sur un clavier ISO, car en plein milieu du clavier. Il est notamment utilisé en
		anglais avec les combinaisons <kbd-sortie>SK</kbd-sortie>,
		<kbd-sortie>CK</kbd-sortie>, etc. Sur un clavier Ergodox, ce problème s’atténue, en particulier
		sur les claviers concaves de type Kinesis Advantage ou Glove80.
	</li>
	<li>Les touches <kbd>Q</kbd> et <kbd>Z</kbd> pourraient aussi être critiquées, car elles nécessitent des extensions de l’auriculaire droit, étant sur une autre colonne que celle de repos.</li>
</ul>

<h3>Non compatible avec les claviers compacts</h3>
<p>
	Certains claviers ont moins de touches, par exemple en n’ayant que 6 colonnes, voire seulement 5,
	par main. <Nom></Nom> a été conçu pour exploiter toutes les touches d’un clavier standard, donc 6 colonnes
	à gauche et 7 à droite. Sur la dernière colonne de droite, il n’y a cependant que les touches mortes
	<kbd class="morte">◌̂</kbd>
	et <kbd class="morte">◌̈</kbd> qui seront beaucoup plus rarement utilisées. Avec <NomPlus
	></NomPlus>, ces touches deviennent même inutiles, car elles sont réalisables autrement.
</p>
<p>
	Il n’en demeure pas moins que <Nom></Nom> n’est pas 1DFH (1u distance from home). Les lettres accentuées
	du français étant en accès direct avec <Nom></Nom>, il est impossible de réaliser une disposition
	1DFH, car il y a trop de touches à placer. La disposition <a href="https://ergol.org">Ergo-L</a> est
	quant à elle une disposition 1DFH, mais au prix d’une touche morte permettant de réaliser les accents.
</p>
<p>
	Une solution simple pour adapter <Nom></Nom> à un clavier plus compact serait de supprimer la touche
	<kbd class="morte">◌̈</kbd>
	qui peut déjà être réalisée en <kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>T</kbd> (T pour Tréma).
	De même, la touche <kbd>Ê</kbd> pourrait être remplacée par la touche morte
	<kbd class="morte">◌̂</kbd>. En Fait, la touche morte de tréma pourrait même être en
	<kbd>Shift</kbd> de cette touche morte circonflexe. Mais tout ceci n’est pas idéal, et les espaces
	insécables et fines insécables respectivement disponibles en <kbd>AltGr</kbd> +
	<kbd class="morte">◌̈</kbd>
	et <kbd>Shift</kbd> + <kbd class="morte">◌̈</kbd> ne seront plus disponibles.
</p>
<p class="encadre">
	<b>Note :</b> Une version 1DFH de <Nom></Nom> a été développée. Elle est disponible sur la page de
	benchmarks ainsi que sur la page de téléchargements, par installation via Kalamine.
</p>

<h3>Quelques <SFB />s restants</h3>
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
		<kbd>SH</kbd> n’est pas très agréable à réaliser sur un clavier ISO à cause du décalage des colonnes.
		En revanche, sur un clavier Ergodox, c’est une combinaison très agréable à réaliser.
	</li>
</ul>
<p class="encadre">
	<b>Note :</b> Tous ces problèmes de <SFB></SFB>s sont résolus grâce à l’utilisation de <NomPlus
	></NomPlus>, y compris pour les <SFB></SFB>s encore plus rares qui ne sont pas listés ici.
	<i class="fa-duotone fa-face-smile"></i>
</p>

<h3>Alternance des mains non maximale</h3>
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

<h3>Manque de logique pour certains placements de touches</h3>
<p>
	La touche <kbd>À</kbd> était auparavant au-dessus du <kbd>A</kbd> et la touche <kbd>È</kbd>
	en-dessous du <kbd>E</kbd>. C’était logique, le A avec le A et le E avec le E. En outre,
	<kbd>AltGr</kbd>
	+ <kbd>È</kbd> donnait <kbd-sortie>\</kbd-sortie>, en miroir de <kbd>AltGr</kbd> + <kbd>É</kbd>
	qui donne <kbd-sortie>/</kbd-sortie>, tandis que <kbd>AltGr</kbd> + <kbd>À</kbd> donnait
	<kbd-sortie>`</kbd-sortie>.
</p>
<p>
	Cependant, les touches <kbd>À</kbd> et <kbd>È</kbd> ont depuis été interverties. En effet, <NomPlus
	></NomPlus> utilisant beaucoup la touche <kbd>À</kbd>, il convenait de la mettre sous un doigt
	fort et non plus sur l’auriculaire. Les symboles en <kbd>AltGr</kbd> ont en revanche été
	conservés, car le <kbd>\</kbd> est plus fréquemment utilisé que le <kbd>`</kbd>, en particulier en
	LaTeX. En résulte un placement moins logique des caractères en <kbd>AltGr</kbd> pour ces deux touches.
</p>

<h3>Manque de caractères et non optimisation pour les autres langues</h3>
<p>
	<Nom></Nom> possède peu de touches mortes et de couches de symboles. En effet, la disposition ne se
	prétend pas être exhaustive en incorporant tous les alphabets des langues européennes comme le BÉPO,
	ou encore le cyrillique, l’écriture phonétique, les pièces d’échec, etc. comme Optimot. Ces couches
	n’intéressent que peu d’utilisateurs et occupent des emplacements du clavier très accessibles pour
	une utilisation très rare. En outre, <Nom></Nom> a été optimisée pour le français et l’anglais, elle
	n’a pas été pensée pour être utilisée dans d’autres langues.
</p>
<p>
	La philosophie derrière <Nom /> est de fournir une base de réflexion, mais pas nécessairement de promouvoir
	l’utilisation de la disposition « Ergopti ». Rien ne vaut une disposition créée sur-mesure pour vos
	usages. Par exemple, si vous voulez écrire régulièrement en allemand, il serait judicieux de mettre
	la touche morte des trémas à un endroit plus accessible. De même, si vous écrivez souvent en espagnol,
	il faudrait trouver un emplacement pour la lettre <kbd-sortie>Ñ</kbd-sortie> (actuellement
	réalisable en
	<kbd>^</kbd>
	+ <kbd>N</kbd>), etc. Sachant tout de même que <Nom></Nom> n’a pas été optimisée pour ces langues et
	n’est probablement pas la disposition la plus adaptée si vous écrivez principalement dans celles-ci.
</p>
