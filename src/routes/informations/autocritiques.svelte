<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
</script>

<h2>Autocritiques</h2>

<h3>L’importance des compromis</h3>
<p>
	Il est évident qu’il n’est pas possible de maximiser plusieurs paramètres simultanément. Bien que
	largement supérieure à de nombreuses dispositions telles qu’AZERTY et même BÉPO, <Ergopti /> est donc
	malheureusement loin d’être parfaite. En effet, la création d’une disposition est une affaire de compromis.
	Des choix ont dû être effectués pour maximiser chacun des critères d’évaluation sans trop compromettre
	les autres.
</p>
<p>
	Par exemple, le <kbd>E</kbd> n’est pas sur l’index de la rangée de repos. Cela peut sembler
	étrange, tant son apparition est incontournable dans les textes (sauf dans le livre
	<em>La Disparition</em> qui arrive l’exploit de ne jamais l’utiliser). Le <kbd>E</kbd> est la
	lettre la plus fréquente, et de loin. Elle est si fréquente que sur le
	<a href="/#clavier_frequences">clavier affichant les touches les plus utilisées</a>
	de la page d’accueil, une transformation mathématique a été nécessaire pour que les fréquences relatives
	aux autres touches soient visibles et comparables (passage au logarithme). En effet, si l’on affichait
	les fréquences relatives telles quelles, le <kbd>E</kbd> serait tellement plus fréquent qu’il écraserait
	complètement les autres fréquences, rendant impossible de les comparer par un code couleur.
</p>
<p>
	Pourtant, cette lettre n’a pas été placée sur l’index, comme le fait pourtant BÉPO. La raison
	principale est que la mettre ailleurs permet de sensiblement de réduire les <SFB />s. En effet, si
	le <kbd>E</kbd> avait été sur l’index, alors les 6 touches tapées par ce doigt auraient
	possiblement générées des <SFB />s avec le <kbd>E</kbd>. <kbd>E</kbd> s’associe avec quasiment
	toutes les lettres, donc ce serait une très mauvaise idée. Au contraire, la voyelle <kbd>U</kbd>
	ne s’associe pas avec beaucoup de lettres, ce qui la rend beaucoup plus pertinente à cet emplacement.
	D’autant que ce nouvel arrangement des voyelles permet alors de très bons roulements.
</p>
<p>
	En outre, parfois tous les emplacements sont mauvais pour une touche, et il faut choisir le moins
	pire. Par conséquent, <Ergopti /> a évidemment des défauts, dont les principaux sont recensés ici.
</p>

<h3>Distances non optimales</h3>
<ul>
	<li>
		<kbd>E</kbd> est sur le majeur et non sur l’index. Théoriquement, l’index est plus fort et
		devrait donc être l’endroit idéal pour la lettre <kbd>E</kbd> qui est de loin la lettre la plus
		fréquente, loin devant la deuxième lettre la plus fréquente de l’alphabet. Cependant, comme
		l’index se charge de 6 touches, il faut aussi veiller à ne pas le surcharger. Par conséquent, ce
		n’est en réalité pas si grave que cela que le <kbd>E</kbd> soit sur le majeur et non sur l’index.
	</li>
	<li>
		Le <kbd>K</kbd>, bien que très rare en français et peu fréquent en anglais, est à une position
		assez lointaine sur un clavier ISO, car en plein milieu du clavier. Il est notamment utilisé en
		anglais avec les combinaisons <kbd-output>SK</kbd-output>,
		<kbd-output>CK</kbd-output>, etc. Sur un clavier Ergodox, ce problème s’atténue, en particulier
		sur les claviers concaves de type Kinesis Advantage ou Glove80.
	</li>
	<li>
		Les touches <kbd>Q</kbd> et <kbd>Z</kbd> pourraient aussi être critiquées, car elles nécessitent
		des extensions de l’auriculaire droit, étant sur une autre colonne que celle de repos.
		<kbd>Z</kbd> étant très rare et le raccourci <kbd>Ctrl</kbd> + <kbd>Z</kbd> pouvant être réalisé
		avec la main gauche, cela ne pose pas vraiment de problème.
	</li>
	<li>
		Certains pourront aussi critiquer le fait que la touche <kbd>J</kbd> soit trop bien située,
		étant sur un excellent emplacement sur l’index gauche. En effet, cette lettre a l’une des
		fréquences les plus faibles de toutes les lettres, que ce soit en français et en anglais. Si
		cette lettre à été placée ici en <Ergopti></Ergopti>, c’est en vue de l’utilisation d’<ErgoptiPlus
		></ErgoptiPlus>, qui a été pensée dès le début comme une extension de la disposition. Ainsi, ce
		choix de placement de la touche <kbd>J</kbd> est justifié par le fait que cela permet de
		facilement ajouter de nouvelles fonctionnalités à la disposition sans avoir à créer une toute
		nouvelle disposition pour tirer parti de ces nouvelles fonctionnalités sans que cela n’ait
		d’impact négatif. Si la touche magique <kbd>★</kbd> est à cet emplacement, c’est aussi parce que
		c’est sur la colonne du <kbd>U</kbd>, pour éviter le maximum de <SFB></SFB>s lors de la
		conversion de cette touche en touche de répétition.
	</li>
</ul>

<h3>Non compatible avec les claviers compacts</h3>
<p>
	Certains claviers ont moins de touches, par exemple en n’ayant que 6 colonnes, voire seulement 5,
	par main. <Ergopti></Ergopti> a été conçue pour exploiter toutes les touches d’un clavier standard,
	donc 6 colonnes à gauche et 7 à droite. Sur la dernière colonne de droite, il n’y a cependant que les
	touches mortes <kbd class="morte">◌̂</kbd> et <kbd class="morte">◌̈</kbd> qui seront beaucoup plus
	rarement utilisées. Ces touches mortes sont en accès direct sur la septième colonne, mais peuvent
	également être obtenues sur la couche <kbd>ShiftAltGr</kbd> avec <kbd>Shift</kbd> +
	<kbd>AltGr</kbd> + <kbd>Ê</kbd> pour <kbd-output class="morte">◌̂</kbd-output> et <kbd>Shift</kbd>
	+ <kbd>AltGr</kbd> + <kbd>T</kbd> pour le Tréma <kbd-output class="morte">◌̈</kbd-output>.
</p>
<p>
	Il n’en demeure pas moins qu’<Ergopti></Ergopti> n’est pas 1DFH (1u Distance From Home). Les lettres
	accentuées du français étant en accès direct avec <Ergopti></Ergopti>, il est impossible de
	réaliser une disposition 1DFH, car il y a trop de touches à placer par rapport à l’espace
	disponible. La disposition
	<a class="link" href="https://ergol.org">Ergo-L</a> est quant à elle une disposition 1DFH, mais au
	prix d’une touche morte permettant de réaliser les accents. Cela signifie que dans ce genre de dispositions,
	il y a plus de frappes pour écrire un mot, car pour écrire une lettre accentuée, il faut d’abord appuyer
	sur la touche morte, puis sur la lettre.
</p>
<p class="encadre">
	<b>Note :</b> Une version 1DFH d’<Ergopti></Ergopti> a été développée. Elle est disponible sur la
	<a href="/benchmarks">page de benchmarks</a>
	ainsi que sur la <a href="/telechargements">page de téléchargements</a>, par installation via
	Kalamine. Elle utilise le fait qu’<Ergopti></Ergopti> ait été conçue de base pour utiliser de nouvelles
	fonctionnalités grâce à l’emplacement réservé à la touche magique <kbd>★</kbd>. Cependant, les
	gains apportés par cette version 1DFH sont faibles et il est donc recommandé de ne pas l’utiliser,
	sauf si vous avez un clavier compact et n’avez pas d’autre choix.
</p>

<h3>Quelques <SFB />s restants</h3>
<ul>
	<li>
		<kbd>CT</kbd> engendre beaucoup de <SFB />s, mais un <SFB /> avec le <kbd>C</kbd> est de toute
		manière inévitable avec l’une des 4 touches de la homerow droite. Cette combinaison est l’une
		des moins pires : en fréquence d’apparition,
		<kbd-output>NC</kbd-output>
		> <kbd-output>CR</kbd-output> >
		<kbd-output>CT</kbd-output> > <kbd-output>SC</kbd-output>.
	</li>
	<li>
		<kbd>PT</kbd> : il est triste de se dire que pour quelqu’un utilisant une disposition o<span
			class="important">pt</span
		>imisée, l’écriture même de ce mot ne l’est pas…
	</li>
	<li>
		<kbd>EO</kbd> et <kbd>OE</kbd> : bien qu’inexistants en français, ces bigrammes sont
		relativement fréquents en anglais (people, does, etc.)
	</li>
</ul>
<p class="encadre">
	<b>Note :</b> Tous ces problèmes de <SFB></SFB>s sont résolus grâce à l’utilisation d’<ErgoptiPlus
	></ErgoptiPlus>, y compris pour les <SFB></SFB>s encore plus rares qui ne sont pas listés ici.
	<i class="icon-face-smile"><span class="path1"></span><span class="path2"></span></i>
</p>

<h3>Alternance des mains non maximale</h3>
<ul>
	<li>
		<kbd>W</kbd> devrait théoriquement plutôt être du côté droit du clavier, car cette lettre est
		souvent précédée ou suivie d’une voyelle. Toutefois, la placer sur l’index gauche permet de
		mettre cette lettre sur un excellent emplacement tout en n’entraînant aucun <SFB /> supplémentaire
		sur l’index gauche. Ainsi, la distance des doigts aux touches s’en trouve diminuée, et des roulements
		très confortables pour l’anglais sont introduits, notamment avec le <kbd>O</kbd> (<kbd-output
			>WO</kbd-output
		>, <kbd-output>OW</kbd-output>).
	</li>
</ul>

<h3>Manque de logique pour certains placements de touches</h3>
<p>
	La touche <kbd>À</kbd> était auparavant au-dessus du <kbd>A</kbd> et la touche <kbd>È</kbd>
	en-dessous du <kbd>E</kbd>. C’était logique, le A avec le A et le E avec le E. En outre,
	<kbd>AltGr</kbd>
	+ <kbd>È</kbd> donnait <kbd-output>\</kbd-output>, en miroir de <kbd>AltGr</kbd> + <kbd>É</kbd>
	qui donne <kbd-output>/</kbd-output>, tandis que <kbd>AltGr</kbd> + <kbd>À</kbd> donnait
	<kbd-output>`</kbd-output>.
</p>
<p>
	Cependant, les touches <kbd>À</kbd> et <kbd>È</kbd> ont depuis été interverties. En effet, <ErgoptiPlus
	></ErgoptiPlus> utilisant beaucoup la touche <kbd>À</kbd>, il convenait de la mettre sous un doigt
	fort et non plus sur l’auriculaire. Les symboles en <kbd>AltGr</kbd> ont en revanche été
	conservés, car le <kbd>\</kbd> est plus fréquemment utilisé que le <kbd>`</kbd>, en particulier en
	LaTeX. En résulte un placement moins logique des caractères en <kbd>AltGr</kbd> pour ces deux touches.
</p>

<h3>Manque de caractères et non optimisation pour les autres langues</h3>
<p>
	<Ergopti></Ergopti> possède peu de touches mortes et de couches de symboles. En effet, la disposition
	ne se prétend pas être exhaustive en incorporant tous les alphabets des langues européennes comme le
	BÉPO, ou encore le cyrillique, l’écriture phonétique, les pièces d’échec, etc. comme Optimot. Ces couches
	n’intéressent que peu d’utilisateurs et occupent des emplacements du clavier très accessibles pour
	une utilisation très rare.
</p>
<p>
	En outre, <Ergopti></Ergopti> a été optimisée pour le français et l’anglais ; elle n’a pas été pensée
	pour être utilisée dans d’autres langues. Par conséquent, <Ergopti></Ergopti> n’est probablement pas
	la disposition la plus adaptée si vous écrivez dans une langue différente du français et de l’anglais.
</p>
