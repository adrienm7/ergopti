<!-- docs/design/studio-glossary.md -->

# Ergopti Studio glossary

The words Ergopti Studio shows (editor, « Comparer », « Optimiser », layout
manager, benchmarks; on the site and in Ergopti+), so that one concept keeps one
name in every label, help text and error. English and French are written first;
the 19 other locales follow the table at the end, which lists each catalogue's
own word. A new Studio string uses these words; a string that needs a new
concept adds it here in the same commit.

The strings live in `static/ergopti_plus/_shared/core/i18n/data/locales/`
under the `layout_editor.`, `layout_analysis.`, `layout_optimizer.` and
`layout_manager.` keys (skill `i18n`).

## Terms

| Concept                         | English                      | French                                    | Notes                                                                                                |
| ------------------------------- | ---------------------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| The product                     | Ergopti+                     | Ergopti+                                  | Never « ErgoptiPlus » in a label: that is the program file's name.                                   |
| The workspace                   | Ergopti Studio, the Studio   | Ergopti Studio, le Studio                 |                                                                                                      |
| Tabs                            | Edit, Compare, Optimize      | Éditer, Comparer, Optimiser               | In prose, « the Compare tab » / « l’onglet Comparer », never « the Comparer » or « le Comparateur ». |
| Keyboard layout                 | layout                       | disposition                               | Never « mapping » or « keymap » for the whole layout.                                                |
| Physical key                    | key                          | touche                                    |                                                                                                      |
| Keystroke                       | keystroke, press             | frappe                                    | « Share of the presses » / « part des frappes ».                                                     |
| Layer                           | layer                        | couche                                    | Base, Shift, AltGr, Shift + AltGr, a custom layer.                                                   |
| Character level                 | level                        | niveau                                    | What one layer of one key types.                                                                     |
| Dead key                        | dead key                     | touche morte                              |                                                                                                      |
| Modifier                        | modifier                     | modificateur                              | Shift is « Maj » in French, Caps Lock « Verr. Maj ».                                                 |
| Text analysed                   | corpus                       | corpus                                    | « Your own text » / « votre texte »; « My typing » / « ma frappe ».                                  |
| Ergopti’s number for a layout   | score, global score          | score, score global                       | Never « note » in French. An analyser’s own number is also its score.                                |
| One measured quantity           | metric                       | mesure                                    | Never « measure » in English.                                                                        |
| Part of the score from a metric | points                       | points                                    | « Points gained / lost ».                                                                            |
| Weight of a metric              | weight                       | poids                                     |                                                                                                      |
| Not counted in the score        | shown, not scored            | affichée, hors score                      |                                                                                                      |
| Who presses which key           | fingering                    | doigté                                    | « Finger model » is not used.                                                                        |
| Resting row and key             | home row, home key           | rangée de repos, touche de repos          |                                                                                                      |
| Keyboard drawing                | keyboard                     | clavier                                   | Never « map », « board » or « plan ».                                                                |
| Physical size                   | keyboard size                | taille du clavier                         | 100 %, TKL (80 %), 75 %, 65 %, 60 %.                                                                 |
| Layouts to install              | catalogue                    | catalogue                                 | The layout manager’s list and its server.                                                            |
| Layouts to compare              | library                      | bibliothèque                              | The built-in analysis list (cmini, Oxeylyzer).                                                       |
| Same-finger bigram              | same-finger bigrams (SFB)    | bigrammes de même doigt (SFB)             | Each metric name has an « i » help text.                                                             |
| Same-finger skipgram            | same-finger skipgrams (SFS)  | skipgrammes de même doigt (SFS)           |                                                                                                      |
| Lateral stretch                 | lateral stretches (LSB)      | extensions latérales (LSB)                |                                                                                                      |
| Scissors                        | full scissors, half scissors | ciseaux complets, demi-ciseaux            |                                                                                                      |
| Roll                            | inward / outward rolls       | roulements vers l’intérieur / l’extérieur |                                                                                                      |
| Redirect                        | redirects                    | redirections                              |                                                                                                      |
| Other analysers                 | analyser                     | analyseur                                 |                                                                                                      |
| Tick boxes                      | tick, untick                 | cocher, décocher                          |                                                                                                      |

## Button verbs

| Action                                      | English              | French                          |
| ------------------------------------------- | -------------------- | ------------------------------- |
| Read a file into the editor                 | Open                 | Ouvrir                          |
| Bring in several files or another format    | Import               | Importer                        |
| Write a file the user downloads             | Export, Download     | Exporter, Télécharger           |
| Keep the work                               | Save                 | Enregistrer                     |
| Take out of the layout                      | Remove               | Retirer                         |
| Go back to the shipped values               | Restore the defaults | Rétablir les valeurs par défaut |
| Put on the system                           | Install              | Installer                       |
| Type it through Ergopti+ without installing | Emulate              | Émuler                          |

## Writing rules

- Sentence case everywhere: only the first word and proper names take a
  capital.
- Plain words first; a technical term (SFB, angle mod, seed, LCID) is followed
  by its explanation in the label or in its help text.
- Each metric and each setting has a short help text (the « i » of the
  Comparer, the `.help` key of the optimizer options).
- An error says what happened and what to do, without blaming the user.
- English uses curly quotes “ ” and the apostrophe ’, Oxford spelling
  (analyse, optimize, colour, catalogue, licence).
- French uses « » with a non-breaking space inside, the apostrophe ’, a
  non-breaking space (U+00A0) before « : » and « % », and a narrow
  non-breaking space (U+202F) before « ; », « ! » and « ? ».
- A label fits a phone width (360 px): column heads and buttons stay short,
  details go in the help text.
- In the other locales, a tab is named by its translated label between the
  catalogue’s usual quotes.

## The words in each locale

From the catalogues (layout_analysis.table.layout, worst.keys,
layout_editor.layer.selector, kind.dead_key, corpus.label, table.score,
details.metric_column, fingering.title, studio.tab.edit, studio.tab.compare,
layout_optimizer.run). A translation of a Studio string uses its locale’s word.

| Locale | Layout       | Keys      | Layer    | Dead key        | Corpus    | Score                      |
| ------ | ------------ | --------- | -------- | --------------- | --------- | -------------------------- |
| en     | Layout       | Keys      | Layer    | Dead key        | Corpus    | Score                      |
| fr     | Disposition  | Touches   | Couche   | Touche morte    | Corpus    | Score                      |
| ar     | التخطيط      | المفاتيح  | الطبقة   | مفتاح ميت       | المدوَّنة | النتيجة                    |
| cs     | Rozložení    | Klávesy   | Vrstva   | Mrtvá klávesa   | Korpus    | Skóre                      |
| da     | Layout       | Taster    | Lag      | Død tast        | Korpus    | Score                      |
| de     | Layout       | Tasten    | Ebene    | Tottaste        | Korpus    | Punktzahl (column: Punkte) |
| es     | Distribución | Teclas    | Capa     | Tecla muerta    | Corpus    | Puntuación                 |
| he     | פריסה        | מקשים     | שכבה     | מקש מת          | קורפוס    | ציון                       |
| hi     | लेआउट        | कुंजियाँ  | लेयर     | डेड कुंजी       | कॉर्पस    | स्कोर                      |
| it     | Layout       | Tasti     | Livello  | Tasto morto     | Corpus    | Punteggio                  |
| ja     | 配列         | キー      | レイヤー | デッドキー      | コーパス  | スコア                     |
| ko     | 배열         | 키        | 레이어   | 데드 키         | 말뭉치    | 점수                       |
| nl     | Indeling     | Toetsen   | Laag     | Dode toets      | Corpus    | Score                      |
| no     | Oppsett      | Taster    | Lag      | Død tast        | Korpus    | Poeng, poengsum            |
| pl     | Układ        | Klawisze  | Warstwa  | Klawisz martwy  | Korpus    | Wynik                      |
| pt     | Layout       | Teclas    | Camada   | Tecla morta     | Corpus    | Pontuação                  |
| ru     | Раскладка    | Клавиши   | Слой     | Мёртвая клавиша | Корпус    | Оценка, балл (points)      |
| sv     | Layout       | Tangenter | Lager    | Död tangent     | Korpus    | Poäng                      |
| tr     | Düzen        | Tuşlar    | Katman   | Ölü tuş         | Derlem    | Puan                       |
| uk     | Розкладка    | Клавіші   | Шар      | Мертва клавіша  | Корпус    | Оцінка, бал (points)       |
| zh     | 布局         | 按键      | 层       | 死键            | 语料      | 得分                       |

| Locale | Metric   | Fingering      | Edit tab      | Compare tab | Optimize        |
| ------ | -------- | -------------- | ------------- | ----------- | --------------- |
| en     | Metric   | Fingering      | Edit          | Compare     | Optimize        |
| fr     | Mesure   | Doigté         | Éditer        | Comparer    | Optimiser       |
| ar     | المقياس  | توزيع الأصابع  | تحرير         | مقارنة      | تحسين           |
| cs     | Metrika  | Prstoklad      | Upravit       | Porovnat    | Optimalizovat   |
| da     | Mål      | Fingersætning  | Rediger       | Sammenlign  | Optimér         |
| de     | Kennzahl | Fingersatz     | Bearbeiten    | Vergleichen | Optimieren      |
| es     | Métrica  | Digitación     | Editar        | Comparar    | Optimizar       |
| he     | מדד      | אצבוע          | עריכה         | השוואה      | אופטימיזציה     |
| hi     | माप      | अँगुली-क्रम    | संपादित करें  | तुलना करें  | ऑप्टिमाइज़ करें |
| it     | Metrica  | Diteggiatura   | Modifica      | Confronta   | Ottimizza       |
| ja     | 指標     | 運指           | 編集          | 比較        | 最適化          |
| ko     | 지표     | 운지법         | 편집          | 비교        | 최적화          |
| nl     | Maatstaf | Vingerzetting  | Bewerken      | Vergelijken | Optimaliseren   |
| no     | Mål      | Fingersetting  | Rediger       | Sammenlign  | Optimaliser     |
| pl     | Miara    | Palcowanie     | Edytuj        | Porównaj    | Optymalizuj     |
| pt     | Métrica  | Dedilhado      | Editar        | Comparar    | Otimizar        |
| ru     | Метрика  | Аппликатура    | Редактировать | Сравнить    | Оптимизировать  |
| sv     | Mått     | Fingersättning | Redigera      | Jämför      | Optimera        |
| tr     | Ölçüt    | Parmak düzeni  | Düzenle       | Karşılaştır | İyileştir       |
| uk     | Метрика  | Аплікатура     | Редагувати    | Порівняти   | Оптимізувати    |
| zh     | 指标     | 指法           | 编辑          | 比较        | 优化            |
