<script>
	import Nom from '$lib/composants/Nom.svelte';
	import Nom_Plus from '$lib/composants/Nom_Plus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
	import EnsembleClavier from '$lib/composants/clavier/Ensemble_Clavier.svelte';
</script>

<h2>Disposition clavier optimisée</h2>

<div class="accordion">
	<section>
		<input type="checkbox" name="acc" id="acc1" />
		<label for="acc1">
			<span class="numero-faq" />
			<h3>Distance des doigts aux touches</h3>
		</label>
		<div class="content">
			<h4>Optimisation de la rangée du milieu</h4>
			<p>
				En dactylographie, il est enseigné que les doigts doivent reposer sur la rangée du milieu (<kbd
					>QSDF</kbd
				>
				et <kbd>JKLM</kbd>
				en AZERTY). L’idée est de taper une touche, puis de toute suite replacer le doigt sur cette rangée
				pour être capable de bouger rapidement dans n’importe quelle direction.
			</p>
			<p>
				Il est alors logique de se dire que nos doigts étant la plupart du temps sur la rangée du
				milieu, autant y placer les lettres les plus fréquemment utilisées. En faisant cela, il n’y
				a presque plus besoin de bouger les doigts, juste à presser les lettres de la rangée de
				repos et parfois atteindre la rangée supérieure ou inférieure pour les lettres les moins
				fréquentes. Pourtant, AZERTY est pire qu’une disposition aléatoire sur ce point : la
				quasi-totalité des touches les plus utilisées sont sur la rangée du dessus. Effectivement, <kbd
					>E</kbd
				>
				est de loin la lettre la plus fréquente. Viennent ensuite les voyelles <kbd>A</kbd>,
				<kbd>I</kbd>, <kbd>U</kbd> et <kbd>O</kbd>, ainsi que les consonnes
				<kbd>S</kbd>, <kbd>N</kbd>, <kbd>T</kbd> et <kbd>R</kbd>.
			</p>
			<p>
				Par conséquent, <Nom /> place évidemment ces lettres sur la rangée du milieu. En résulte la nécessité
				de beaucoup moins bouger ses doigts et un meilleur confort.
			</p>
			<h4>Optimisation selon la force des doigts</h4>
			<p>
				Une fois que les lettres les plus fréquentes ont été placées sur la rangée du milieu, il
				reste encore beaucoup à faire. En effet, chaque doigt a une force différente. Ainsi, un
				pouce a plus de force qu’un index, qui a plus de force qu’un majeur, qui a plus de force
				qu’un annulaire, qui a plus de force qu’un auriculaire. Vous pouvez facilement vous en
				rendre compte en pressant fort de l’index sur une table, puis en essayent de faire de même
				avec votre auriculaire.
			</p>
			<p>
				Par conséquent, ce constat de la force des doigts pris en compte, les meilleurs emplacements
				sont ceux sur la rangée de repos, en partant de l’index pour aller vers l’annulaire. Puis,
				les meilleurs emplacements seront sur les touches au-dessus et en-dessous de la rangée de
				repos, en partant là encore de l’index pour aller vers l’annulaire.
			</p>
			<p>
				La rangée des chiffres est donc encore moins accessible, car il faut traverser deux rangées
				depuis la rangée de repos pour l’atteindre. C’est pour cette raison que laisser le <kbd
					>É</kbd
				>
				sur cette ligne comme en AZERTY est une très mauvaise idée, car cette lettre est beaucoup utilisée
				en français. Par exemple, en français, le <kbd>É</kbd> est 5 fois plus fréquent que le
				<kbd>J</kbd>, dont la touche est pourtant en AZERTY sur l’un des meilleurs emplacements du
				clavier : l’index.
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
			<p>
				Comme vous pouvez le constater sur le clavier ci-dessus, les lettres les plus fréquentes
				sont bien sur la rangée du milieu en <Nom />. Effectivement, la lettre la plus fréquente, le
				<kbd>E</kbd>, est en rouge. Viennent ensuite en orange les voyelles et consonnes les plus
				fréquentes. Enfin, les lettres en vert, voire bleu, sont les moins fréquentes de toutes.
			</p>
			<p>
				Attention toutefois, car ces fréquences vont varier selon le texte analysé et la langue de
				celui-ci. Vous trouverez plus de détails sur la page <a href="/benchmarks">Benchmarks</a>.
			</p>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc2" />
		<label for="acc2">
			<span class="numero-faq" />
			<h3>Minimisation des SFBs</h3>
		</label>
		<div class="content">
			<p>
				La disposition AZERTY est extrêmement mauvaise au vu de la distance nécessaire pour
				atteindre les touches les plus fréquentes. Toutefois, c’est loin d’être son seul défaut.
				L’un de ses autres défauts majeurs est son extrêmement grand nombre de <SFB />s.
			</p>
			<p>
				Qu’est-ce qu’un SFB ? C’est le fait de devoir taper deux touches d’affilée avec exactement
				le même doigt. Par exemple, c’est taper <kbd>CE</kbd> en AZERTY : il faut d’abord utiliser
				le majeur gauche pour descendre d’une rangée et atteindre le <kbd>C</kbd>, puis remonter de
				deux rangées pour atteindre le <kbd>E</kbd>. Avec <Nom />, le <kbd>C</kbd> est sur l’index
				droit sur la rangée du haut et le <kbd>E</kbd> est directement sur la rangée du milieu, sur
				le majeur gauche. Il y a donc 3 fois plus de déplacements entre rangées avec AZERTY, et le
				pire c’est que <kbd>CE</kbd> est une combinaison extrêmement fréquente.
			</p>
			<p>
				Cette combinaison de deux touches est appelée <em>bigramme</em> (ou <em>digramme</em>). Pour
				optimiser une disposition clavier, il faut s’assurer que les bigrammes les plus fréquents ne
				se fassent pas avec le même doigt : on parle de limiter les <em>Same Finger Bigrams</em>.
			</p>
			<p>
				Cette tâche est bien plus difficile qu’on le pense, car certaines lettres comme le <kbd
					>E</kbd
				>
				ou le <kbd>R</kbd> se combinent avec presque toutes les autres. Il faut alors choisir de les
				regrouper avec les lettres faisant les bigrammes les moins fréquents. Il est donc impossible
				de réduire totalement les <SFB />s, mais il est tout de même possible de les réduire
				drastiquement.
			</p>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc3" />
		<label for="acc3">
			<span class="numero-faq" />
			<h3>Alternance des mains</h3>
		</label>
		<div class="content">
			<p>
				L’alternance des mains est très importante pour garantir une bonne <strong
					>fluidité de frappe</strong
				>, et donc un meilleur confort. L’objectif est d’essayer d’avoir le plus d’alternance des
				mains possible lors de la frappe de texte : main droite pour une touche, ensuite main gauche
				pour la touche suivante, puis main droite, main gauche, etc.
			</p>
			<p>
				Cette alternance des mains permet de <strong>ne pas surutiliser l’une des deux mains</strong
				> en tapant avec la majorité du texte, au détriment de l’autre main qui resterait au-dessus de
				sa partie du clavier, à attendre de pouvoir enfin entrer en jeu. Ainsi, avec une bonne alternance
				des mains, pendant qu’une main frappe une touche, l’autre peut se replacer sur la rangée du milieu
				et se préparer à frapper la suivante.
			</p>
			<p>
				Si la touche suivante est sur la même main que la touche précédente (sauf roulement, cf. le
				point suivant), la frappe sera moins confortable. Imaginez que vous deviez atteindre le <kbd
					>C</kbd
				>
				de l’AZERTY, puis le <kbd>T</kbd>, pour écrire <kbd>CT</kbd>, un bigramme très courant en
				français et anglais. Dans ce cas, vous devez d’abord légèrement abaisser votre main pour que
				le majeur atteigne la rangée du bas pour taper
				<kbd>C</kbd>. Puis, il faut que l’index atteigne quant à lui la rangée du haut pour taper
				<kbd>T</kbd>. En résulte un sentiment d’inconfort avec deux doigts proches mais qui doivent
				aller dans des directions différentes. Au contraire, en "parallélisant" les frappes sur les
				deux mains, le résultat se révèle bien plus satisfaisant.
			</p>
			<p>
				L’alternance des mains a une limite. Il est impossible d’alterner parfaitement à chaque
				frappe. C’est pourquoi, une fois une alternance maximale atteinte, il faut encore améliorer
				l’expérience de frappe dans le cas où deux touches de la même main doivent être frappées
				d’affilée. C’est là qu’interviennent les roulements, présentés en détail dans le point
				suivant.
			</p>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc4" />
		<label for="acc4">
			<span class="numero-faq" />
			<h3>Optimisation des roulements</h3>
		</label>
		<div class="content">
			<p>
				L’optimisation de l’alternance des mains fait que lors de l’utilisation d’une main pour
				frapper une touche, il y a de fortes probabilités que le frappe suivante se fasse avec
				l’autre main. Toutefois, cela n’arrive pas dans la totalité des cas, c’est pourquoi il
				convient de s’assurer que le plus possible de frappes inter-mains se fassent à l’aide de
				roulements.
			</p>
			<p>
				Pour moi, un "roulement" désigne un déplacement sur deux doigts consécutifs et jamais à plus
				d’une rangée d’écart. Il y peu d’informations sur le sujet en ligne ; un roulement a
				probablement une définition plus large que la mienne, mais alors dans ce cas le côté "qui
				roule" est selon moi perdu. À la limite si c’est de l’index à l’auriculaire, mais pas de
				l’index à l’annulaire par exemple.
			</p>
			<p>
				En conclusion, un roulement est pour moi le <kbd>ST</kbd> du Bépo (idéalement, car mouvement
				horizontal), sinon le <kbd>LS</kbd> du Bépo, mais pas le <kbd>GL</kbd> ni le
				<kbd>TR</kbd>
				du Bépo. La disposition <Nom /> a été construite avec pour contrainte principale de permettre
				de réaliser les bigrammes consonne-consonne et voyelle-voyelle les plus courants grâce à des
				roulements, de préférence sur des doigts consécutifs dans un mouvement horizontal.
			</p>
			<petit-espace />
			<EnsembleClavier
				emplacement={'clavier-roulements'}
				type={'iso'}
				couche={'Visuel'}
				couleur={'non'}
				plus={'oui'}
				controles={'roulements'}
			/>
			<petit-espace />
			<h4>Très bons bigrammes voyelle-voyelle</h4>
			<ul class="margin-top-2">
				<li><kbd>AI</kbd></li>
				<li><kbd>IE</kbd></li>
				<li><kbd>EU</kbd></li>
				<li><kbd>OI</kbd></li>
				<li><kbd>OU</kbd></li>
			</ul>

			Avec même quelques trigrammes très confortables :
			<ul class="margin-top-2">
				<li><kbd>AIE</kbd> notamment pour écrire <span class="hyper text-bold">AIE</span>NT</li>
				(avec en plus NT qui est lui aussi un roulement, que demander de plus ?)
				<li><kbd>IEU</kbd></li>
				<li><kbd>YOU</kbd></li>
			</ul>
			<h4>Très bons bigrammes consonne-consonne</h4>
			<ul class="margin-top-2">
				<li><kbd>SN</kbd></li>
				<li><kbd>NT</kbd></li>
				<li><kbd>TR</kbd></li>
				<li><kbd>RT</kbd></li>
				<li><kbd>RS</kbd></li>
				<li><kbd>NS</kbd></li>
				<li>
					<kbd>CH</kbd> ce bigramme est extraordinaire, une fois habitué il est difficile de s’en passer
				</li>
				<li><kbd>PL</kbd></li>
				<li>
					<kbd>LD</kbd> surtout fréquent en anglais (O<span class="hyper text-bold">LD</span>, COU<span
						class="hyper text-bold">LD</span
					>, SHOU<span class="hyper text-bold">LD</span>, WOU<span class="hyper text-bold">LD</span
					>, etc.)
				</li>
			</ul>
			<h4>Autres bons bigrammes</h4>
			<ul class="margin-top-2">
				<li>
					<kbd>OW</kbd> très utilisé en anglais (ALL<span class="hyper text-bold">OW</span>
					, D<span class="hyper text-bold">OW</span>N, FOLL<span class="hyper text-bold">OW</span>,
					H<span class="hyper text-bold">OW</span>, KN<span class="hyper text-bold">OW</span>, N<span
						class="hyper text-bold">OW</span
					>, <span class="hyper text-bold">OW</span>N, SH<span class="hyper text-bold">OW</span>,
					etc.)
				</li>
				<li>
					<kbd>WO</kbd> très utilisé en anglais (T<span class="hyper text-bold">WO</span>,
					<span class="hyper text-bold">WO</span>MAN, <span class="hyper text-bold">WO</span>RD,
					<span class="hyper text-bold">WO</span>RK, <span class="hyper text-bold">WO</span>RLD,
					<span class="hyper text-bold">WO</span>RTH, <span class="hyper text-bold">WO</span>ULD,
					etc.)
				</li>
				<li>
					<kbd>="</kbd> utilisé en programmation pour assigner une chaîne de caractères à une variable
				</li>
				<li><kbd>+=</kbd> utilisé en programmation pour incrémenter</li>
			</ul>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc5" />
		<label for="acc5">
			<span class="numero-faq" />
			<h3>Placement logique des touches</h3>
		</label>
		<div class="content">
			<p>
				Afin de <strong> faciliter la mémorisation</strong> ainsi que de
				<strong>réduire la charge cognitive</strong>, les touches de la disposition sont, le plus
				possible, <span style="text-decoration: underline;"> placées logiquement</span>. Ceci en
				particulier sur la couche <kbd>AltGr</kbd> :
			</p>

			<ul>
				<li>
					<kbd>AltGr</kbd> + <kbd>À</kbd> ➜ <kbd-sortie>`</kbd-sortie> car le
					<span class="hyper text-bold">`</span> est au-dessus du A
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>B</kbd> ➜ <kbd-sortie>@</kbd-sortie> car aro<span
						class="hyper text-bold">B</span
					>ase
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>C</kbd> ➜ <kbd-sortie>ç</kbd-sortie>
					car la cédille est sous le <span class="hyper text-bold">C</span>
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>D</kbd> ➜ <kbd-sortie>$</kbd-sortie>
					car c’est le première lettre de <span class="hyper text-bold">D</span>ollar
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>É</kbd> ➜ <kbd-sortie>/</kbd-sortie>
					car le <span class="hyper text-bold">/</span> est au-dessus du E
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>È</kbd> ➜ <kbd-sortie>\</kbd-sortie>
					car le <span class="hyper text-bold">\</span> est au-dessus du E
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>F</kbd> ➜ <kbd-sortie>*</kbd-sortie>
					car c’est la première lettre de <span class="hyper text-bold">F</span>ois
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>H</kbd> ➜ <kbd-sortie>#</kbd-sortie>
					car c’est la première lettre de <span class="hyper text-bold">H</span>ashtag
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>L</kbd> ➜ <kbd-sortie>=</kbd-sortie> car éga<span
						class="hyper text-bold">L</span
					>
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>M</kbd> ➜ <kbd-sortie>&</kbd-sortie> car le nom de ce symbole est
					a<span class="hyper text-bold">M</span>persand
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>P</kbd> ➜ <kbd-sortie>+</kbd-sortie>
					car c’est la première lettre de <span class="hyper text-bold">P</span>lus
				</li>
				<li>
					<kbd>AltGr</kbd> + <kbd>V</kbd> ➜ <kbd-sortie>|</kbd-sortie> car c’est la barre
					<span class="hyper text-bold">V</span>erticale
				</li>
			</ul>

			<mini-espace />

			<p>D’autres sont placées par paires l’une à côté de l’autre :</p>
			<ul>
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
			<mini-espace />
			<p>
				À noter que les touches sont aussi placées le plus possible par distance selon leur
				fréquence d’utilisation. Ainsi, les touches très utilisées comme les <kbd>()</kbd>,
				<kbd>{'{}'}</kbd>, etc. sont toutes sur la rangée du milieu et sur les doigts les plus
				forts.
			</p>
			<p>
				Le <kbd>$</kbd> est l’un des seuls symboles à ne pas être sur un emplacement logique (le
				<kbd>D</kbd>
				de <span class="hyper text-bold">D</span>ollar). Ceci parce qu’il est plus intéressant de
				mettre le <kbd>"</kbd> sur cette lettre, afin d’avoir un excellent roulement <kbd>="</kbd>.
			</p>
			<h4>Ponctuations avec espace insécable automatique</h4>
			<p>
				Enfin, les ponctuations <kbd>;</kbd>, <kbd>:</kbd>, <kbd>?</kbd> et <kbd>!</kbd> ont une
				particularité. Lors de l’utilisation de <kbd>Shift</kbd>, elles sont automatiquement
				envoyées avec une espace insécable qui les précède. En revanche, avec
				<kbd>AltGr</kbd>, la ponctuation seule est renvoyée, notamment pour faire de la
				programmation. Cela permet ainsi d’écrire dans un français impeccable en <kbd>Shift</kbd>,
				tout en programment normalement avec la couche <kbd>AltGr</kbd>, qui contient d’ailleurs
				tout le reste des symboles nécessaires à l’écriture de code.
			</p>
			<p>
				Ainsi, il est facile de se rappeler où est quoi : <strong
					>le français est en <kbd>Shift</kbd>, la programmation est en <kbd>AltGr</kbd></strong
				>.
			</p>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc6" />
		<label for="acc6">
			<span class="numero-faq" />
			<h3>Chiffres en accès direct</h3>
		</label>
		<div class="content">
			<p>
				Les chiffres sont en accès direct sur les dispositions QWERTY ou encore DVORAK, mais pas en
				AZERTY. Chaque manière de faire a ses avantages, car en AZERTY les symboles sont alors en
				accès direct et donc plus facilement réalisables. En revanche, il devient compliqué d’écrire
				un nombre en plein milieu d’une phrase, car cela nécessite de passer en <kbd>Shift</kbd> momentanément
				pour l’écrire.
			</p>
			<p>
				Le passage des chiffres en accès direct permet d’<strong
					>écrire très rapidement des nombres</strong
				>
				en milieu de phrase. La rangée des nombres n’est de toute façon pas très accessible, donc il
				vaut mieux placer les symboles qu’elle contenait sur la couche <kbd>AltGr</kbd>, plus
				proches des mains car sur les 3 rangées du milieu pour ne pas avoir à trop bouger les
				doigts.
			</p>
		</div>
	</section>
	<section>
		<input type="checkbox" name="acc" id="acc7" />
		<label for="acc7">
			<span class="numero-faq" />
			<h3>Optimisation pour l’utilisation à une main</h3>
		</label>
		<div class="content">
			<p>
				Lors de l’utilisation d’un ordinateur, la plupart du temps la souris est tenue de la main
				droite et la main gauche repose près de la partie gauche du clavier. Lorsqu’il faut rentrer
				du texte ou taper sur une touche, il est bien souvent nécessaire de ramener la main droite
				de la souris à la partie droite du clavier, de taper dessus, puis de retourner à sa souris
				pour continuer la navigation.
			</p>
			<p>
				Par conséquent, il est aussi important de s’assurer que, grâce à sa disposition clavier,
				beaucoup d’actions courantes puissent se réaliser avec la seule main gauche afin de <strong
					>ne pas avoir à lâcher la souris</strong
				>.
			</p>
			<p>
				La version de <Nom /> adaptée aux claviers de type Ergodox est ainsi complètement optimisée sur
				ce critère, car des touches <kbd>Copier</kbd>, <kbd>Coller</kbd>, <kbd>Couper</kbd> et
				<kbd>Alt+Tab</kbd>
				sont directement inclues à gauche du clavier.
			</p>
			<p>
				La version ISO ne peut quant à elle malheureusement pas bénéficier de ces touches de
				raccourci, car les touches à sa gauche sont déjà occupées par les touches
				<kbd>Shift</kbd>, <kbd>Capslock</kbd> et <kbd>Tab</kbd> contrairement à l’Ergodox où l’on
				peut placer ces touches sous les pouces. <Nom_Plus /> donne toutefois le moyen de contourner
				ces limites.
			</p>
			<p>
				Dans tous les cas, le <kbd>=</kbd> a au moins été dupliqué à gauche en accès direct. Cela
				permet de faire facilement les raccourcis sur Excel comme <kbd>=</kbd> et <kbd>Alt</kbd> +
				<kbd>=</kbd>. En effet, normalement, le <kbd>=</kbd> se situe en <kbd>AltGr</kbd> +
				<kbd>L</kbd>.
			</p>
		</div>
	</section>
</div>
