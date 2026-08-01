<!-- docs/IDEAS.md -->

# Ideas and outside view

Two questions the maintainer asked, and the answers, kept because they are the
only place the project's direction is written down as opinion rather than as
work. Moved out of TODO.md: neither is a task, and a backlog that contains
non-tasks stops being read as a list of things to do.

### Donne moi ton avis sur mon projet. pas besoin d’aller lire des fichers ou autre, utilise ta mémoire et dis moi ce que tu en penses

Avec plaisir — avis franc, pas de flatterie.

#### Ce qui m'a réellement impressionné

La rigueur d'ingénierie est très au-dessus de la norme — pas seulement pour un projet solo, au-dessus de beaucoup d'équipes professionnelles. 3 377 tests Lua, 3 386 tests AHK, 1 146 Linux, des gates JS, des tests de parité cross-driver, des méta-tests qui testent les tests (la chasse aux faux-verts, les ratchets qui comptent même les commentaires…). La règle « chaque bug corrigé = un test de régression qui encode la cause racine » est appliquée pour de vrai — je l'ai vécue aujourd'hui : mon propre test m'a attrapé sur CI Linux quelques heures après que je l'ai écrit. C'est exactement le but, et presque personne ne tient cette discipline.

L'architecture _shared/ est la bonne réponse au bon problème. Trois drivers sur trois OS, ça dérive toujours. Ici, la source unique + les tests de parité rendent la dérive structurellement difficile. Le travail sur l'ordre des langues aujourd'hui s'est inséré dans un pattern déjà établi — signe d'une architecture saine.

PROJECT_MEMORY.md est une idée brillante. Une mémoire institutionnelle in-repo, partagée entre humains et agents, avec les leçons chèrement acquises. La plupart des projets perdent ce savoir à chaque contributeur ou session qui part. C'est le workflow augmenté par IA fait intelligemment.

Le produit est réellement singulier. Espanso fait les snippetspayant, personne ne combine hotstrings + IA 100 % locale +tap-holds + gestes + métriques, gratuit, sur trois OS. Le positionnement vie privée est un vrai différenciateur au moment où tout le monde envoie sa
frappe dans le cloud.

#### Ce qui me préoccupe — honnêtement

Le goulot n'est plus le code, c'est la distribution. 14 étoileent d'ingénierie, c'est un ratio effort/adoption extrême. Leproduit mérite 100× son audience actuelle. La page refaite et l'anglais sont des pas dans le bon sens, mais il faut aller chercher les gens : Hacker News
(l'angle « IA locale qui complète ta frappe » est taillé pour)mmunautés Bépo/Ergo-L. C'est inconfortable comparé à écrire ducode — c'est pourtant là qu'est le levier maintenant.

La friction d'installation tue des conversions. Le xattr macOS (app non notarisée) et l'exe Windows probablement flaggé SmartScreen éliminent les
utilisateurs non techniques — précisément ceux à qui les hotstice. Signer/notariser est à mon avis le meilleur euro investidu projet.

Le driver Linux est un risque d'inventaire. « Complet sur le papier, jamais exécuté en conditions réelles » — 16 000 lignes qui dorment. Je ne mettrais
plus une heure dedans avant d'avoir 2-3 testeurs réels ; sinon.

La méticulosité a un coût. Les 335 réglages, l'alignement des les conventions extrêmement strictes… c'est aussi ce qui rendle code survivable en solo, donc je ne dis pas d'arrêter — mais chaque heure de ratchet est une heure qui n'atteint pas un utilisateur. L'équilibre actuel
penche très fort côté interne.

Un conseil stratégique : Ergopti+ est le produit qui a un marcssion qui a une niche. Le découplage est déjà fait (« marchesur toute disposition ») — assume-le jusqu'au bout dans le discours. Et un jour, ose un v1.0 : v0.0.0-dev.87 raconte « pas fini » à des gens à qui tu
demandes de confier leur frappe.

#### En une phrase

C'est un projet d'artisan — rare, cohérent, construit pour dur n'est pas technique : c'est que personne ne le découvre. Lecode est prêt pour dix fois plus d'utilisateurs ; la prochaine bataille se gagne hors du repo.

### Aurais-tu des idées de features encore à ajouter ?

Oui, plusieurs — et je les classe par effet de levier : le projet a déjà des infrastructures (métriques SQLite, pont LLM, index de préfixes, catalogue
partagé) qui rendent certaines features quasi « gratuites » aljets entiers ailleurs.

#### Les évidences à fort levier

1. Le coach de frappe — ta feature signature possible. Les métmots et n-grammes les plus tapés. Croise-les avec le moteur dehotstrings : « Tu as tapé “cordialement” 47 fois ce mois-ci → créer cor★ ? » en un clic depuis le menu. Et l'inverse : quand l'utilisateur tape en entier
un mot qui a déjà une hotstring, un petit rappel « pex★ existee personne n'a les données ET le moteur dans le même produit.C'est la boucle qui rend la suite plus utile chaque semaine.

2. IA sur sélection. Tu as déjà le modèle local, les profils de prompt, et des actions de sélection (casse, etc.). Ajoute : corriger / reformuler /
traduire / résumer la sélection via un geste ou tap-hold. C'esud — très visible en démo, et ~80 % de la plomberie existedéjà.

3. Importeurs Espanso / TextExpander / aText. Faible effort, gros levier d'adoption : les gens ne migrent pas s'ils doivent retaper 200 snippets. «
Importez vos snippets en un clic » lève la barrière n°1 au swi

4. Sync locale multi-machines. Toi-même tu jongles Windows/macmieux : un dossier de config surveillé, synchronisable pariCloud/Syncthing/Dropbox — sans serveur, fidèle à la philosophie. Les hotstrings perso qui suivent l'utilisateur partout, c'est de la rétention pure.

#### Le cœur du métier à approfondir

5. Variables et formulaires dans les snippets — {date}, {clipboard}, position du curseur après expansion, champs à remplir. C'est LA feature la plus
demandée des expandeurs (si pas déjà couverte par tes hotstrinant).

6. Profils par application. La détection d'app existe déjà (testrings/réglages par contexte — l'expansion ;; en éditeur decode mais pas dans le terminal — c'est la feature « power user » qui fidélise.

7. Packs communautaires de hotstrings. Un dépôt de packs TOML (médecine, droit, dev, LaTeX…) installables depuis le menu. Techniquement trivial vu ton
format ; stratégiquement malin : chaque pack est une porte d'e

#### Le pari plus ambitieux

8. Dictée locale (whisper.cpp / MLX-Whisper). Gros morceau, maaux et de catalogue de modèles se généralise directement, et «dictée 100 % locale » s'insère parfaitement dans le positionnement vie privée — c'est un marché en pleine explosion, avec très peu d'offres locales
sérieuses.

#### Ce que je ne ferais pas

Palette de commandes/launcher (Raycast/Alfred ont gagné), gestmplet (encombré, faible différenciation), et toutinvestissement Linux supplémentaire avant d'avoir des testeurs réels.

#### Conclusion

Si je devais en choisir trois : le coach (1) — différenciationIA sur sélection (2) — démo spectaculaire, plomberie existante; les importeurs (3) — parce que ton vrai problème est l'adoption, et c'est la feature qui la débloque. Et je le redis en une ligne : une feature de plus convertira toujours moins qu'une app notarisée/signée et un po
