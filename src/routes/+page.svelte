<script>
	import Nom from '$lib/composants/Nom.svelte';
	import Nom_Plus from '$lib/composants/Nom_Plus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
	import EnsembleClavier from '$lib/composants/clavier/Ensemble_Clavier.svelte';
</script>

<div class="fullheight">
	<div>
		<h1 class="titre">
			Disposition clavier<br /><span class="hyper">—&nbsp;Hyper</span><span class="texte"
				>Texte&nbsp;—</span
			>
		</h1>
	</div>

	<EnsembleClavier
		emplacement={'clavier-presentation'}
		type={'iso'}
		couche={'Visuel'}
		couleur={'non'}
		plus={'non'}
		controles={'oui'}
	/>
</div>

<mini-espace />

<div class="contenu">
	<p class="important">
		<Nom /> est une disposition clavier destinée à taper majoritairement du français et de l’anglais.
		Elle se veut la plus <span class="hyper">optimale</span> possible. Comment atteindre cet objectif ?
		C’est ce qui vous sera présenté sur cette page.
	</p>

	<h2>Disposition clavier optimisée</h2>

	<div class="container">
		<div class="tab">
			<input type="checkbox" name="acc" id="acc1" />
			<label for="acc1">
				<span class="numero-faq" />
				<h3>Alternance des mains</h3>
			</label>
			<div class="content">
				<p>
					La première étape dans la création d’<Nom /> a été de classer les touches du clavier en deux
					groupes : main gauche et main droite. L’objectif de cela est d’essayer d’avoir le plus d’alternance
					des mains possible lors de la frappe de texte : main droite, puis gauche, puis droite, etc.
					Cette alternance des mains permet de ne pas surutiliser l’une des deux mains en tapant la majorité
					du texte avec au détriment de l’autre main. Cela permet aussi de gagner légèrement en confort
					et vitesse car pendant qu’une main tape, l’autre peut se replacer en position de repos et se
					préparer à taper la touche suivante.
				</p>
				<p>
					Pour optimiser ce critère, les voyelles ont toutes été placées d’un côté du clavier.
					Celles-ci étant majoritairement précédées et suivies de consonnes, cela amène
					immédiatement une grande alternance des mains. À noter que cette idée est loin d’être
					nouvelle, car elle est déjà appliquée dans presque toutes les dispositions alternatives :
					Dvorak, BÉPO, etc.
				</p>
				<p>
					Dans le cas d’<Nom />, les voyelles ont été placées sur le côté gauche. La raison est que
					sur la plupart des claviers (i.e ceux qui sont non matriciels) il y a moins de touches sur
					ce côté. Le côté droit a en effet trois colonnes de touches pour l’auriculaire alors que
					l’auriculaire gauche n’en a qu’une. Ces nombreux emplacements sont précieux, surtout pour
					les langues ayant besoin de caractères supplémentaires comme les accents en français.
				</p>
			</div>
		</div>
		<div class="tab">
			<input type="checkbox" name="acc" id="acc2" />
			<label for="acc2">
				<span class="numero-faq" />
				<h3>Distance des doigts aux touches</h3>
			</label>
			<div class="content">
				<p>
					La deuxième étape dans la création de la disposition a été de placer les touches les plus
					souvent utilisées les plus proches possible des doigts. Les doigts sont effectivement
					toujours censés reposer sur la rangée de repos du clavier (la ligne du milieu). Il est
					donc logique de chercher à placer sur cette rangée les lettres les plus utilisées pour
					réduire les déplacements des doigts aux touches.
				</p>
				<p>
					En outre, chaque doigt a une force différente. Ainsi, un pouce a plus de force qu’un
					index, qui a plus de force qu’un majeur, qui a plus de force qu’un annulaire, qui a plus
					de force qu’un auriculaire. Par conséquent, les meilleurs emplacements sont ceux sur la
					rangée de repos, en partant de l’index à l’annulaire. Puis, les meilleurs emplacements
					seront sur les colonnes au-dessus et en-dessous de la rangée de repos, en partant là
					encore de l’index à l’annulaire. La rangée des chiffres est donc la moins accessible,
					c’est pour cela que laisser le <kbd>É</kbd> sur cette ligne comme en AZERTY est une très mauvaise
					idée, car cette lettre est beaucoup utilisée en français.
				</p>

				<mini-espace />

				<EnsembleClavier
					emplacement={'clavier-freq'}
					type={'iso'}
					couche={'Visuel'}
					couleur={'freq'}
					plus={'non'}
					controles={'non'}
				/>
			</div>
		</div>
		<div class="tab">
			<input type="checkbox" name="acc" id="acc3" />
			<label for="acc3">
				<span class="numero-faq" />
				<h3>Minimisation des <SFB />s</h3>
			</label>
			<div class="content">
				<p>
					Lorem, ipsum dolor sit amet consectetur adipisicing elit. Mollitia at exercitationem fuga
					laudantium commodi alias odio quibusdam praesentium earum impedit?
				</p>
			</div>
		</div>
		<div class="tab">
			<input type="checkbox" name="acc" id="acc4" />
			<label for="acc4">
				<span class="numero-faq" />
				<h3>Optimisation des roulements</h3>
			</label>
			<div class="content">
				<p>
					Pour moi, un "roulement" désigne plutôt un déplacement sur deux doigts consécutifs et
					jamais à plus d’une rangée d’écart. Il y peu d’informations sur le sujet en ligne ; un
					roulement a probablement une définition plus large que la mienne, mais alors dans ce cas
					le côté "qui roule" est selon moi perdu. À la limite si c’est de l’index à l’auriculaire,
					mais pas de l’index à l’annulaire par exemple. En conclusion, un roulement est pour moi le
					ST du Bépo (idéalement, car mouvement horizontal), sinon le LS du Bépo, mais pas le GL ni
					le TR du Bépo. La disposition Optim7 a été construite avec pour contrainte principale de
					permettre de réaliser les digrammes consonne-consonne les plus courants grâce à des
					roulements, de préférence sur des doigts consécutifs dans un mouvement horizontal.
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
			</div>
		</div>
		<div class="tab">
			<input type="checkbox" name="acc" id="acc5" />
			<label for="acc5">
				<span class="numero-faq" />
				<h3>Placement logique des touches</h3>
			</label>
			<div class="content">
				<p>
					Afin de faciliter la mémorisation, les touches sont placées logiquement, en particulier
					sur la couche AltGr. Ainsi :
				</p>

				<ul class="margin-top-2">
					<li>
						<kbd>AltGr</kbd> + <kbd>À</kbd> ➜ <kbd-sortie>`</kbd-sortie> Le
						<span class="hyper text-bold">`</span> sur le A
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>B</kbd> ➜ <kbd-sortie>@</kbd-sortie> aro<span
							class="hyper text-bold">B</span
						>ase
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>C</kbd> ➜ <kbd-sortie>ç</kbd-sortie>
						<span class="hyper text-bold">C</span> cédille
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>D</kbd> ➜ <kbd-sortie>$</kbd-sortie>
						<span class="hyper text-bold">D</span>ollar
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>É</kbd> ➜ <kbd-sortie>/</kbd-sortie>
						le <span class="hyper text-bold">/</span> sur le E
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>È</kbd> ➜ <kbd-sortie>\</kbd-sortie>
						le <span class="hyper text-bold">\</span> sur le E
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>H</kbd> ➜ <kbd-sortie>#</kbd-sortie>
						<span class="hyper text-bold">H</span>ashtag
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>L</kbd> ➜ <kbd-sortie>=</kbd-sortie> éga<span
							class="hyper text-bold">L</span
						>
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>M</kbd> ➜ <kbd-sortie>&</kbd-sortie> a<span
							class="hyper text-bold">M</span
						>persand
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>P</kbd> ➜ <kbd-sortie>+</kbd-sortie>
						<span class="hyper text-bold">P</span>lus
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>V</kbd> ➜ <kbd-sortie>|</kbd-sortie> barre
						<span class="hyper text-bold">V</span>erticale
					</li>
				</ul>

				<petit-espace />

				<p>D’autres sont placés par paires l’une à côté de l’autre :</p>
				<ul class="margin-top-2">
					<li>
						<kbd>AltGr</kbd> + <kbd>A</kbd> ➜ <kbd-sortie>[</kbd-sortie> et <kbd>AltGr</kbd> +
						<kbd>I</kbd>
						➜ <kbd-sortie>]</kbd-sortie>
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>E</kbd> ➜ <kbd-sortie>{'{'}</kbd-sortie> et <kbd>AltGr</kbd> +
						<kbd>U</kbd>
						➜ <kbd-sortie>{'}'}</kbd-sortie>
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>S</kbd> ➜ <kbd-sortie>(</kbd-sortie> et <kbd>AltGr</kbd> +
						<kbd>N</kbd>
						➜ <kbd-sortie>)</kbd-sortie>
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>T</kbd> ➜ <kbd-sortie>{'<'}</kbd-sortie> et <kbd>AltGr</kbd> +
						<kbd>R</kbd>
						➜ <kbd-sortie>{'>'}</kbd-sortie>
					</li>
					<li>
						<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>T</kbd> ➜ <kbd-sortie>⩽</kbd-sortie> et
						<kbd>Shift</kbd>
						+ <kbd>AltGr</kbd> +
						<kbd>R</kbd>
						➜ <kbd-sortie>⩾</kbd-sortie>
					</li>
					<li>
						<kbd>AltGr</kbd> + <kbd>G</kbd> ➜ <kbd-sortie>«</kbd-sortie> et <kbd>AltGr</kbd> +
						<kbd>X</kbd>
						➜ <kbd-sortie>»</kbd-sortie>
					</li>
					<li>
						<kbd>Shift</kbd> + <kbd>AltGr</kbd> + <kbd>G</kbd> ➜ <kbd-sortie>“</kbd-sortie> et
						<kbd>Shift</kbd>
						+ <kbd>AltGr</kbd> +
						<kbd>X</kbd>
						➜ <kbd-sortie>”</kbd-sortie>
					</li>
				</ul>
			</div>
		</div>
		<div class="tab">
			<input type="checkbox" name="acc" id="acc6" />
			<label for="acc6">
				<span class="numero-faq" />
				<h3>Chiffres en accès direct</h3>
			</label>
			<div class="content">
				<p>
					Les chiffres sont en accès direct sur les dispositions QWERTY, mais pas en AZERTY. Chaque
					manière de faire a ses avantages, car en AZERTY les symboles sont alors en accès direct et
					plus facilement réalisables. En revanche, il devient alors compliqué d’écrire un chiffre
					ou un nombre en plein milieu de phrase, car cela nécessite de passer en Shift.
				</p>
				<p>
					De plus, une autre de mes modifications est le passage des chiffres en accès direct, car
					maintenir Shift enfoncé pour écrire rapidement un nombre n’est vraiment pas pratique. J’en
					profite pour déplacer les caractères qui étaient auparavant en accès direct sur la rangée
					des chiffres. Ils se retrouvent en AltGr sur les 3 rangées du milieu pour ne pas avoir à
					trop bouger les doigts.
				</p>
			</div>
		</div>
		<div class="tab">
			<input type="checkbox" name="acc" id="acc7" />
			<label for="acc7">
				<span class="numero-faq" />
				<h3>Optimisation pour l’utilisation à une main</h3>
			</label>
			<div class="content">
				<p>
					Le <kbd>=</kbd> a été dupliqué à gauche en accès direct. Cela permet de faire facilement
					les raccourcis sur Excel comme <kbd>=</kbd> et <kbd>Alt</kbd> + <kbd>=</kbd>. Normalement,
					le
					<kbd>=</kbd>
					se situe en <kbd>AltGr</kbd> + <kbd>L</kbd>.
				</p>
			</div>
		</div>
	</div>

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
		<li>E sur le majeur et non l’index à cause des roulements et <SFB />s</li>
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

	<h2>Autocritiques</h2>

	<h3>L’importance des compromis</h3>
	<p>
		Il n’est évidemment pas possible de maximiser tous ces paramètres en même temps. Par conséquent,
		certains choix ont dus être faits.
	</p>
	<p>
		Notamment, le E n’est pas sur l’index de la rangée de repos. Ce qui est pourtant étrange, tant
		son apparition est fréquente dans les textes. C’est la lettre la plus fréquente et de loin.
		Pourtant, elle ne se trouve pas sur l’index notamment afin de réduire les <SFB />s. Si le E
		avait été sur l’index, alors les 6 touches tapées par ce doigt auraient possiblement fait des <SFB
		/>s avec le E. E s’associe avec quasiment toutes les lettres, donc ce serait une très mauvaise
		idée. Au contraire, la voyelle U ne s’associe pas avec beaucoup de lettres, donc elle est bien
		mieux à cet emplacement. D’autant que cet arrangemement des voyelles permet alors de très bons
		roulements.
	</p>

	<h3>Points d’amélioration</h3>

	<ul class="paragraphe">
		<li>SC mais parce que c’est à la moins pire position</li>
		<li>PT</li>
		<li>EO et OE pour l’anglais</li>
		<li>K est assez loin, surtout pour l’anglais avec ses SK, CK, etc.</li>
	</ul>

	<h2><span class="glow">★</span> Pour aller plus loin</h2>
	<div class="important">
		<p>
			<Nom_Plus /> permet d’avoir une disposition encore meilleure. Les <SFB />s sont éradiqués, les
			roulements sont améliorés et les doigts ont encore moins de distance à parcourir. Cependant,
			ces excellents résultats sont le fruit d’une fraude. En effet, ils nécessitent d’avoir un
			logiciel permettant de se faire des raccourcis personnalisés comme AutoHotkey. Il faudra aussi
			accepter d’apprendre des enchaînements de touches supplémentaires.
		</p>
	</div>
</div>
