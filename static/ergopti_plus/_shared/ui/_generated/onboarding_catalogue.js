// _shared/ui/_generated/onboarding_catalogue.js

// ==========================================
// AUTO-GENERATED — do not edit manually
// Source: static/ergopti_plus/_shared/modules/features/manifest.toml [onboarding]
// Run: npm run codegen:onboarding-catalogue
// ==========================================

// The first-run wizard pages as page data. A page cannot read the manifest,
// so it loads this script before script.js, which renders it.
(function (global) {
	'use strict';

	global.ONBOARDING_CATALOGUE = {
		"schema_version": 1,
		"order": [
			"tap_holds",
			"shortcuts",
			"gestures",
			"keyboard_layout",
			"hotstrings",
			"llm",
			"metrics"
		],
		"value_separator": "➔",
		"texts": {
			"hotstrings/autocorrection.toml": {
				"ar": "تصحيح تلقائي",
				"cs": "Automatická oprava",
				"da": "Autokorrektur",
				"de": "Autokorrektur",
				"en": "Autocorrection",
				"es": "Autocorrección",
				"fr": "Autocorrection",
				"he": "תיקון אוטומטי",
				"hi": "स्वत: सुधार",
				"it": "Correzione automatica",
				"ja": "自動修正",
				"ko": "자동 수정",
				"nl": "Autocorrectie",
				"no": "Autokorrektur",
				"pl": "Autokorekta",
				"pt": "Autocorreção",
				"ru": "Автокоррекция",
				"sv": "Autokorrigering",
				"tr": "Otomatik düzeltme",
				"uk": "Автовиправлення",
				"zh": "自动纠错"
			},
			"hotstrings/autocorrection.toml#caps": {
				"ar": "أحرف كبيرة تلقائية: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"cs": "Automatická velká písmena: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"da": "Automatisk stort begyndelsesbogstav: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"de": "Automatische Großschreibung: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"en": "Auto capitalisation: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"es": "Mayúsculas automáticas: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"fr": "Majuscules automatiques : chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"he": "אותיות גדולות אוטומטיות: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"hi": "स्वचालित बड़े अक्षर: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"it": "Maiuscole automatiche: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"ja": "自動大文字化：chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"ko": "자동 대문자: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"nl": "Automatische hoofdletters: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"no": "Automatisk stor bokstav: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"pl": "Automatyczne wielkie litery: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"pt": "Maiúsculas automáticas: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"ru": "Автоматические заглавные буквы: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"sv": "Automatisk versalisering: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"tr": "Otomatik büyük harf: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"uk": "Автоматичні великі літери: chatgpt = ChatGPT, powerpoint = PowerPoint, …",
				"zh": "自动大写：chatgpt = ChatGPT，powerpoint = PowerPoint，…"
			},
			"hotstrings/magickey.toml": {
				"ar": "مفتاح ★ وتوسيع النص",
				"cs": "Klávesa ★ a rozšíření textu",
				"da": "★-tast og tekstudvidelse",
				"de": "★-Taste und Texterweiterung",
				"en": "★ key and text expansion",
				"es": "Tecla ★ y expansión de texto",
				"fr": "Touche ★ et expansion de texte",
				"he": "מקש ★ והרחבת טקסט",
				"hi": "★ कुंजी और टेक्स्ट विस्तार",
				"it": "Tasto ★ e espansione testo",
				"ja": "★キーとテキスト展開",
				"ko": "★ 키와 텍스트 확장",
				"nl": "★-toets en tekstuitbreiding",
				"no": "★-tast og tekstutvidelse",
				"pl": "Klawisz ★ i rozszerzenie tekstu",
				"pt": "Tecla ★ e expansão de texto",
				"ru": "Клавиша ★ и расширение текста",
				"sv": "★-tangent och textutvidgning",
				"tr": "★ tuşu ve metin genişletme",
				"uk": "Клавіша ★ та розширення тексту",
				"zh": "★ 键与文本扩展"
			},
			"layouts/registry/ergopti/hotstrings/magickeyreplace.toml#replace": {
				"ar": "تحويل مفتاح إلى مفتاح ★",
				"cs": "Transformovat klávesu na klávesu ★",
				"da": "Omdanne en tast til ★-tasten",
				"de": "Eine Taste in die ★-Taste umwandeln",
				"en": "Transform a key into the ★ key",
				"es": "Transformar una tecla en la tecla ★",
				"fr": "Transformer une touche en touche ★",
				"he": "להפוך מקש למקש ★",
				"hi": "किसी कुंजी को ★ में बदलें",
				"it": "Trasformare un tasto nel tasto ★",
				"ja": "キーを★キーに変換",
				"ko": "키를 ★ 키로 변환",
				"nl": "Een toets omzetten naar de ★-toets",
				"no": "Gjøre en tast om til ★-tasten",
				"pl": "Przekształć klawisz w klawisz ★",
				"pt": "Transformar uma tecla na tecla ★",
				"ru": "Превратить клавишу в клавишу ★",
				"sv": "Omvandla en tangent till ★-tangenten",
				"tr": "Bir tuşu ★ tuşuna dönüştür",
				"uk": "Перетворити клавішу на клавішу ★",
				"zh": "将一个键转换为 ★ 键"
			},
			"layouts/registry/ergopti/hotstrings/repeatcorrections.toml#repeat_corrections": {
				"ar": "تصحيح الإيجابيات الكاذبة لمفتاح ★ التكرار (ê→u)",
				"cs": "Opravy falešných pozitiv opakované klávesy ★ (ê→u)",
				"da": "★ gentast falsk positiv rettelser (ê→u)",
				"de": "Fehlpositivkorrekturen der ★-Wiederholtaste (ê→u)",
				"en": "★ repeat key false positive fixes (ê→u)",
				"es": "Correcciones de falsos positivos de la tecla ★ repetir (ê→u)",
				"fr": "Corrections de faux positifs de la touche ★ répétition (ê→u)",
				"he": "תיקוני חיובי שווא של מקש ★ חוזר (ê→u)",
				"hi": "★ रिपीट कुंजी के गलत-सकारात्मक सुधार (ê→u)",
				"it": "Correzioni falsi positivi tasto ★ ripeti (ê→u)",
				"ja": "★ リピートキー誤検知修正 (ê→u)",
				"ko": "★ 반복 키 오탐 수정 (ê→u)",
				"nl": "★ herhaaltoets fout-positief correcties (ê→u)",
				"no": "★ gjenta-tast falsk positiv rettelser (ê→u)",
				"pl": "Poprawki fałszywych pozytywów klawisza ★ powtórz (ê→u)",
				"pt": "Correções de falsos positivos da tecla ★ repetir (ê→u)",
				"ru": "Исправления ложных срабатываний клавиши ★ повтор (ê→u)",
				"sv": "★ upprepningstangent falskt positiva korrigeringar (ê→u)",
				"tr": "★ tekrar tuşu yanlış pozitif düzeltmeleri (ê→u)",
				"uk": "Виправлення хибно-позитивних спрацювань клавіші ★ повтор (ê→u)",
				"zh": "★ 重复键假阳性修正 (ê→u)"
			},
			"hotstrings/magickey.toml#text_expansion_symbols": {
				"ar": "توسيع النص بالرموز: -->★ = ➜, (v)★ = ✓, …",
				"cs": "Rozšíření textu symboly: -->★ = ➜, (v)★ = ✓, …",
				"da": "Symbol tekstudvidelse: -->★ = ➜, (v)★ = ✓, …",
				"de": "Symbol-Texterweiterung: -->★ = ➜, (v)★ = ✓, …",
				"en": "Symbol text expansion: -->★ = ➜, (v)★ = ✓, …",
				"es": "Expansión de texto con símbolos: -->★ = ➜, (v)★ = ✓, …",
				"fr": "Expansion de texte Symboles : -->★ = ➜, (v)★ = ✓, …",
				"he": "הרחבת טקסט סמלים: -->★ = ➜, (v)★ = ✓, …",
				"hi": "प्रतीक टेक्स्ट विस्तार: -->★ = ➜, (v)★ = ✓, …",
				"it": "Espansione testo simboli: -->★ = ➜, (v)★ = ✓, …",
				"ja": "記号テキスト展開：-->★ = ➜, (v)★ = ✓, …",
				"ko": "기호 텍스트 확장: -->★ = ➜, (v)★ = ✓, …",
				"nl": "Symbool tekstuitbreiding: -->★ = ➜, (v)★ = ✓, …",
				"no": "Symbol tekstutvidelse: -->★ = ➜, (v)★ = ✓, …",
				"pl": "Rozszerzenie tekstu symbolami: -->★ = ➜, (v)★ = ✓, …",
				"pt": "Expansão de texto com símbolos: -->★ = ➜, (v)★ = ✓, …",
				"ru": "Расширение текста символами: -->★ = ➜, (v)★ = ✓, …",
				"sv": "Symbol textutvidgning: -->★ = ➜, (v)★ = ✓, …",
				"tr": "Sembol metin genişletme: -->★ = ➜, (v)★ = ✓, …",
				"uk": "Розширення тексту символами: -->★ = ➜, (v)★ = ✓, …",
				"zh": "符号文本扩展：-->★ = ➜，(v)★ = ✓，…"
			},
			"hotstrings/magickey.toml#text_expansion_symbols_typst": {
				"ar": "توسيع نص رموز Typst: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"cs": "Typst symbolové rozšíření textu: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"da": "Typst symbol tekstudvidelse: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"de": "Typst-Symbol-Texterweiterung: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"en": "Typst symbol text expansion: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"es": "Expansión de texto con símbolos Typst: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"fr": "Expansion de texte Symboles Typst : $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"he": "הרחבת טקסט סמלי Typst: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"hi": "Typst प्रतीक टेक्स्ट विस्तार: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"it": "Espansione testo simboli Typst: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"ja": "Typst記号テキスト展開：$eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"ko": "Typst 기호 텍스트 확장: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"nl": "Typst symbool tekstuitbreiding: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"no": "Typst symbol tekstutvidelse: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"pl": "Typst rozszerzenie tekstu symbolami: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"pt": "Expansão de texto com símbolos Typst: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"ru": "Расширение текста символами Typst: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"sv": "Typst symbol textutvidgning: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"tr": "Typst sembol metin genişletme: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"uk": "Розширення тексту символами Typst: $eq.not$ = ≠, $PP$ = ℙ, $integral$ = ∫ …",
				"zh": "Typst 符号文本扩展：$eq.not$ = ≠，$PP$ = ℙ，$integral$ = ∫ …"
			},
			"layouts/registry/ergopti/hotstrings/distancesreduction.toml": {
				"ar": "تقليل المسافات",
				"cs": "Snížení vzdáleností",
				"da": "Afstandsreduktion",
				"de": "Distanzreduktion",
				"en": "Distance reduction",
				"es": "Reducción de distancias",
				"fr": "Réduction des distances",
				"he": "הפחתת מרחקים",
				"hi": "दूरी में कमी",
				"it": "Riduzione delle distanze",
				"ja": "距離削減",
				"ko": "거리 감소",
				"nl": "Afstandsreductie",
				"no": "Avstandsreduksjon",
				"pl": "Redukcja odległości",
				"pt": "Redução de distâncias",
				"ru": "Уменьшение расстояний",
				"sv": "Avståndsminskning",
				"tr": "Mesafe azaltma",
				"uk": "Зменшення відстаней",
				"zh": "距离减少"
			},
			"layouts/registry/ergopti/hotstrings/distancesreduction.toml#qu": {
				"ar": "Q تصبح QU عند اتباعها بحرف علة: qa = qua, qo = quo, …",
				"cs": "Q se stává QU, když následuje samohláska: qa = qua, qo = quo, …",
				"da": "Q bliver QU efterfulgt af en vokal: qa = qua, qo = quo, …",
				"de": "Q wird zu QU, wenn ein Vokal folgt: qa = qua, qo = quo, …",
				"en": "Q becomes QU when followed by a vowel: qa = qua, qo = quo, …",
				"es": "Q se convierte en QU ante vocal: qa = qua, qo = quo, …",
				"fr": "Q devient QU quand elle est suivie d’une voyelle : qa = qua, qo = quo, …",
				"he": "Q הופך ל-QU כשאחריה תנועה: qa = qua, qo = quo, …",
				"hi": "Q के बाद स्वर आने पर QU बन जाता है: qa = qua, qo = quo, …",
				"it": "Q diventa QU davanti a vocale: qa = qua, qo = quo, …",
				"ja": "Qの後に母音が来るとQUになる：qa = qua, qo = quo, …",
				"ko": "Q 뒤에 모음이 오면 QU가 됨: qa = qua, qo = quo, …",
				"nl": "Q wordt QU gevolgd door een klinker: qa = qua, qo = quo, …",
				"no": "Q blir QU etterfulgt av vokal: qa = qua, qo = quo, …",
				"pl": "Q staje się QU przed samogłoską: qa = qua, qo = quo, …",
				"pt": "Q torna-se QU antes de vogal: qa = qua, qo = quo, …",
				"ru": "Q становится QU перед гласной: qa = qua, qo = quo, …",
				"sv": "Q blir QU följt av vokal: qa = qua, qo = quo, …",
				"tr": "Q, ünlüden önce QU olur: qa = qua, qo = quo, …",
				"uk": "Q стає QU перед голосною: qa = qua, qo = quo, …",
				"zh": "Q 后接元音变为 QU：qa = qua，qo = quo，…"
			},
			"layouts/registry/ergopti/hotstrings/distancesreduction.toml#comma_j": {
				"ar": "فاصلة + حرف علة تعطي J: ,a = ja, ,o = jo, ,’ = j’, …",
				"cs": "Čárka + Samohláska dává J: ,a = ja, ,o = jo, ,’ = j’, …",
				"da": "Komma + Vokal giver J: ,a = ja, ,o = jo, ,’ = j’, …",
				"de": "Komma + Vokal ergibt J: ,a = ja, ,o = jo, ,’ = j’, …",
				"en": "Comma + Vowel gives J: ,a = ja, ,o = jo, ,’ = j’, …",
				"es": "Coma + Vocal da J: ,a = ja, ,o = jo, ,’ = j’, …",
				"fr": "Virgule + Voyelle donne J : ,a = ja, ,o = jo, ,’ = j’, …",
				"he": "פסיק + תנועה נותן J: ,a = ja, ,o = jo, ,’ = j’, …",
				"hi": "अल्पविराम + स्वर J देता है: ,a = ja, ,o = jo, ,’ = j’, …",
				"it": "Virgola + Vocale dà J: ,a = ja, ,o = jo, ,’ = j’, …",
				"ja": "カンマ + 母音 = J：,a = ja, ,o = jo, ,’ = j’, …",
				"ko": "쉼표 + 모음 = J: ,a = ja, ,o = jo, ,’ = j’, …",
				"nl": "Komma + Klinker geeft J: ,a = ja, ,o = jo, ,’ = j’, …",
				"no": "Komma + Vokal gir J: ,a = ja, ,o = jo, ,’ = j’, …",
				"pl": "Przecinek + Samogłoska daje J: ,a = ja, ,o = jo, ,’ = j’, …",
				"pt": "Vírgula + Vogal dá J: ,a = ja, ,o = jo, ,’ = j’, …",
				"ru": "Запятая + Гласная даёт J: ,a = ja, ,o = jo, ,’ = j’, …",
				"sv": "Komma + Vokal ger J: ,a = ja, ,o = jo, ,’ = j’, …",
				"tr": "Virgül + Ünlü J verir: ,a = ja, ,o = jo, ,’ = j’, …",
				"uk": "Кома + Голосна дає J: ,a = ja, ,o = jo, ,’ = j’, …",
				"zh": "逗号 + 元音 = J：,a = ja，,o = jo，,’ = j’，…"
			},
			"layouts/registry/ergopti/hotstrings/distancesreduction.toml#comma_far_letters": {
				"ar": "الفاصلة تكتب حروفاً بعيدة: ,è=z و ,y=k و ,c=ç و ,x=où و ,s=q",
				"cs": "Čárka píše excentriky: ,è=z a ,y=k a ,c=ç a ,x=où a ,s=q",
				"da": "Komma skriver eksentriske bogstaver: ,è=z og ,y=k og ,c=ç og ,x=où og ,s=q",
				"de": "Komma tippt außermittige Buchstaben: ,è=z und ,y=k und ,c=ç und ,x=où und ,s=q",
				"en": "Comma types eccentric letters: ,è=z and ,y=k and ,c=ç and ,x=où and ,s=q",
				"es": "La coma escribe letras excéntricas: ,è=z y ,y=k y ,c=ç y ,x=où y ,s=q",
				"fr": "Virgule permet de taper des lettres excentrées : ,è=z et ,y=k et ,c=ç et ,x=où et ,s=q",
				"he": "פסיק מקליד אותיות רחוקות: ,è=z ו-,y=k ו-,c=ç ו-,x=où ו-,s=q",
				"hi": "अल्पविराम दूर के अक्षर टाइप करता है: ,è=z और ,y=k और ,c=ç और ,x=où और ,s=q",
				"it": "La virgola scrive lettere eccentriche: ,è=z e ,y=k e ,c=ç e ,x=où e ,s=q",
				"ja": "カンマが遠い文字を入力：,è=z、,y=k、,c=ç、,x=où、,s=q",
				"ko": "쉼표가 먼 문자를 입력: ,è=z 및 ,y=k 및 ,c=ç 및 ,x=où 및 ,s=q",
				"nl": "Komma typt verre letters: ,è=z en ,y=k en ,c=ç en ,x=où en ,s=q",
				"no": "Komma skriver eksentriske bokstaver: ,è=z og ,y=k og ,c=ç og ,x=où og ,s=q",
				"pl": "Przecinek wpisuje odległe litery: ,è=z i ,y=k i ,c=ç i ,x=où i ,s=q",
				"pt": "A vírgula escreve letras excêntricas: ,è=z e ,y=k e ,c=ç e ,x=où e ,s=q",
				"ru": "Запятая вводит далёкие буквы: ,è=z и ,y=k и ,c=ç и ,x=où и ,s=q",
				"sv": "Komma skriver excentriskt placerade bokstäver: ,è=z och ,y=k och ,c=ç och ,x=où och ,s=q",
				"tr": "Virgül uzak harfleri yazar: ,è=z ve ,y=k ve ,c=ç ve ,x=où ve ,s=q",
				"uk": "Кома вводить далекі літери: ,è=z та ,y=k та ,c=ç та ,x=où та ,s=q",
				"zh": "逗号输入偏远字母：,è=z 和 ,y=k 和 ,c=ç 和 ,x=où 和 ,s=q"
			},
			"layouts/registry/ergopti/hotstrings/distancesreduction.toml#dead_key_e_circumflex": {
				"ar": "Ê متبوعة بحرف تعمل كمفتاح ميت: êo = ô, êu = û, ês = ß…",
				"cs": "Ê následované písmenem funguje jako mrtvá klávesa: êo = ô, êu = û, ês = ß…",
				"da": "Ê efterfulgt af et bogstav fungerer som en dead key: êo = ô, êu = û, ês = ß…",
				"de": "Ê gefolgt von einem Buchstaben wirkt als Tottaste: êo = ô, êu = û, ês = ß…",
				"en": "Ê followed by a letter acts as a dead key: êo = ô, êu = û, ês = ß…",
				"es": "Ê seguido de una letra actúa como tecla muerta: êo = ô, êu = û, ês = ß…",
				"fr": "Ê suivi d’une lettre agit comme une touche morte : êo = ô, êu = û, ês = ß…",
				"he": "Ê אחרי אות פועלת כמקש מת: êo = ô, êu = û, ês = ß…",
				"hi": "Ê के बाद अक्षर डेड की की तरह काम करता है: êo = ô, êu = û, ês = ß…",
				"it": "Ê seguita da una lettera agisce come tasto morto: êo = ô, êu = û, ês = ß…",
				"ja": "Ê の後に文字が続くとデッドキーとして機能：êo = ô, êu = û, ês = ß…",
				"ko": "Ê 뒤에 문자가 오면 데드키로 작동: êo = ô, êu = û, ês = ß…",
				"nl": "Ê gevolgd door een letter werkt als dode toets: êo = ô, êu = û, ês = ß…",
				"no": "Ê etterfulgt av en bokstav fungerer som en dead key: êo = ô, êu = û, ês = ß…",
				"pl": "Ê po którym następuje litera działa jak martwy klawisz: êo = ô, êu = û, ês = ß…",
				"pt": "Ê seguido de uma letra funciona como tecla morta: êo = ô, êu = û, ês = ß…",
				"ru": "Ê после буквы работает как мёртвая клавиша: êo = ô, êu = û, ês = ß…",
				"sv": "Ê följt av en bokstav fungerar som en dead key: êo = ô, êu = û, ês = ß…",
				"tr": "Ê’nin ardından gelen harf ölü tuş gibi davranır: êo = ô, êu = û, ês = ß…",
				"uk": "Ê після літери працює як мертва клавіша: êo = ô, êu = û, ês = ß…",
				"zh": "Ê 后接字母作为死键：êo = ô，êu = û，ês = ß…"
			},
			"layouts/registry/ergopti/hotstrings/distancesreduction.toml#e_circumflex_e": {
				"ar": "Ê متبوعة بـ E تعطي Œ",
				"cs": "Ê následované E dává Œ",
				"da": "Ê efterfulgt af E giver Œ",
				"de": "Ê gefolgt von E ergibt Œ",
				"en": "Ê followed by E gives Œ",
				"es": "Ê seguido de E da Œ",
				"fr": "Ê suivi de E donne Œ",
				"he": "Ê אחרי E נותן Œ",
				"hi": "Ê के बाद E आने पर Œ मिलता है",
				"it": "Ê seguita da E dà Œ",
				"ja": "Ê の後にEが来るとŒになる",
				"ko": "Ê 뒤에 E가 오면 Œ가 됨",
				"nl": "Ê gevolgd door E geeft Œ",
				"no": "Ê etterfulgt av E gir Œ",
				"pl": "Ê po którym następuje E daje Œ",
				"pt": "Ê seguido de E dá Œ",
				"ru": "Ê после E даёт Œ",
				"sv": "Ê följt av E ger Œ",
				"tr": "Ê'nin ardından E gelirse Œ olur",
				"uk": "Ê після E дає Œ",
				"zh": "Ê 后接 E 得 Œ"
			},
			"layouts/registry/ergopti/hotstrings/distancesreduction.toml#space_around_symbols": {
				"ar": "أضف مسافة قبل وبعد الرموز الناتجة عن التداول وبعد مفتاح [où]",
				"cs": "Přidat mezeru před a za symboly z rolování a za klávesu [où]",
				"da": "Tilføj mellemrum før og efter symboler fra rolls og efter [où]-tasten",
				"de": "Leerzeichen vor und nach durch Läufe erzeugten Symbolen sowie nach der [où]-Taste",
				"en": "Add a space before and after symbols produced by rolls, and after the [où] key",
				"es": "Añade espacio antes y después de los símbolos generados por rodamientos y tras la tecla [où]",
				"fr": "Ajouter un espace avant et après les symboles obtenus par rolls ainsi qu’après la touche [où]",
				"he": "הוסף רווח לפני ואחרי סמלים שנוצרו על ידי גלגולים ואחרי מקש [où]",
				"hi": "रोल्स से बने प्रतीकों के आगे और पीछे और [où] कुंजी के बाद स्पेस जोड़ें",
				"it": "Aggiunge spazio prima e dopo i simboli prodotti dalle rollate e dopo il tasto [où]",
				"ja": "ロールで生成された記号の前後と[où]キーの後にスペースを追加",
				"ko": "롤로 생성된 기호 앞뒤와 [où] 키 뒤에 공백 추가",
				"nl": "Voeg spatie toe voor en na symbolen van rolls en na de [où]-toets",
				"no": "Legg til mellomrom før og etter symboler fra rolls og etter [où]-tasten",
				"pl": "Dodaj spację przed i po symbolach z rolad i po klawiszu [où]",
				"pt": "Adicionar espaço antes e depois dos símbolos das rolagens e após a tecla [où]",
				"ru": "Добавить пробел до и после символов перекатов и после клавиши [où]",
				"sv": "Lägg till mellanslag före och efter symboler från rolls och efter [où]-tangenten",
				"tr": "Rolls’tan üretilen sembollerin önüne ve arkasına ve [où] tuşundan sonra boşluk ekle",
				"uk": "Додати пробіл до і після символів перекатів та після клавіші [où]",
				"zh": "在连击产生的符号前后添加空格，以及在 [où] 键后添加空格"
			},
			"layouts/registry/ergopti/hotstrings/sfbsreduction.toml": {
				"ar": "تقليل SFBs",
				"cs": "Redukce SFBs",
				"da": "SFB-reduktion",
				"de": "SFB-Reduktion",
				"en": "SFB reduction",
				"es": "Reducción de SFBs",
				"fr": "Réduction des SFBs",
				"he": "הפחתת SFBs",
				"hi": "SFB कमी",
				"it": "Riduzione SFBs",
				"ja": "SFB削減",
				"ko": "SFB 감소",
				"nl": "SFB-reductie",
				"no": "SFB-reduksjon",
				"pl": "Redukcja SFBs",
				"pt": "Redução de SFBs",
				"ru": "Снижение SFBs",
				"sv": "SFB-reduktion",
				"tr": "SFB azaltma",
				"uk": "Зменшення SFBs",
				"zh": "SFB 减少"
			},
			"layouts/registry/ergopti/hotstrings/sfbsreduction.toml#comma": {
				"ar": "فاصلة + صامت يصحح SFBs كثيرة: ,t = pt، ,d = ds، ,p = xp، …",
				"cs": "Čárka + Souhláska opravuje mnoho SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"da": "Komma + Konsonant retter mange SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"de": "Komma + Konsonant korrigiert viele SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"en": "Comma + Consonant fixes many SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"es": "Coma + Consonante corrige muchos SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"fr": "Virgule + Consonne corrige de très nombreux SFBs : ,t = pt, ,d= ds, ,p = xp, …",
				"he": "פסיק + עיצור מתקן SFBs רבים: ,t = pt, ,d = ds, ,p = xp, …",
				"hi": "अल्पविराम + व्यंजन कई SFBs ठीक करता है: ,t = pt, ,d = ds, ,p = xp, …",
				"it": "Virgola + Consonante corregge molti SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"ja": "カンマ + 子音が多くのSFBを修正：,t = pt, ,d = ds, ,p = xp, …",
				"ko": "쉼표 + 자음이 많은 SFB를 수정: ,t = pt, ,d = ds, ,p = xp, …",
				"nl": "Komma + Medeklinker corrigeert veel SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"no": "Komma + Konsonant retter mange SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"pl": "Przecinek + Spółgłoska poprawia wiele SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"pt": "Vírgula + Consoante corrige muitos SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"ru": "Запятая + Согласная исправляет многие SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"sv": "Komma + Konsonant rättar många SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"tr": "Virgül + Ünsüz çok sayıda SFBs düzeltir: ,t = pt, ,d = ds, ,p = xp, …",
				"uk": "Кома + Приголосна виправляє багато SFBs: ,t = pt, ,d = ds, ,p = xp, …",
				"zh": "逗号 + 辅音修正大量 SFB：,t = pt，,d = ds，,p = xp，…"
			},
			"layouts/registry/ergopti/hotstrings/sfbsreduction.toml#e_circ": {
				"ar": "Ê + مفتاح اليد اليسرى يصحح 4 SFBs: êé = oe, éê = eo, ê, = u, وê. = u.",
				"cs": "Ê + klávesa levé ruky opravuje 4 SFBs: êé = oe, éê = eo, ê, = u, a ê. = u.",
				"da": "Ê + venstrehåndstast retter 4 SFBs: êé = oe, éê = eo, ê, = u, og ê. = u.",
				"de": "Ê + Linke-Hand-Taste korrigiert 4 SFBs: êé = oe, éê = eo, ê, = u, und ê. = u.",
				"en": "Ê + left-hand key fixes 4 SFBs: êé = oe, éê = eo, ê, = u, and ê. = u.",
				"es": "Ê + tecla de la mano izquierda corrige 4 SFBs: êé = oe, éê = eo, ê, = u, y ê. = u.",
				"fr": "Ê + touche sur la main gauche corrige 4 SFBs : êé = oe, éê = eo, ê, = u, et ê. = u.",
				"he": "Ê + מקש יד שמאל מתקן 4 SFBs: êé = oe, éê = eo, ê, = u, ו-ê. = u.",
				"hi": "Ê + बाएं हाथ की कुंजी 4 SFBs ठीक करती है: êé = oe, éê = eo, ê, = u, और ê. = u.",
				"it": "Ê + tasto della mano sinistra corregge 4 SFBs: êé = oe, éê = eo, ê, = u, e ê. = u.",
				"ja": "Ê + 左手キーが4つのSFBを修正：êé = oe, éê = eo, ê, = u, ê. = u",
				"ko": "Ê + 왼손 키가 4개의 SFB를 수정: êé = oe, éê = eo, ê, = u, ê. = u",
				"nl": "Ê + linkerhandtoets corrigeert 4 SFBs: êé = oe, éê = eo, ê, = u, en ê. = u.",
				"no": "Ê + venstrehandstast retter 4 SFBs: êé = oe, éê = eo, ê, = u, og ê. = u.",
				"pl": "Ê + klawisz lewej ręki poprawia 4 SFBs: êé = oe, éê = eo, ê, = u, i ê. = u.",
				"pt": "Ê + tecla da mão esquerda corrige 4 SFBs: êé = oe, éê = eo, ê, = u, e ê. = u.",
				"ru": "Ê + клавиша левой руки исправляет 4 SFBs: êé = oe, éê = eo, ê, = u, и ê. = u.",
				"sv": "Ê + vänsterhandstangent rättar 4 SFBs: êé = oe, éê = eo, ê, = u, och ê. = u.",
				"tr": "Ê + sol el tuşu 4 SFBs düzeltir: êé = oe, éê = eo, ê, = u, ve ê. = u.",
				"uk": "Ê + клавіша лівої руки виправляє 4 SFBs: êé = oe, éê = eo, ê, = u, та ê. = u.",
				"zh": "Ê + 左手键修正 4 个 SFB：êé = oe，éê = eo，ê, = u，ê. = u"
			},
			"layouts/registry/ergopti/hotstrings/sfbsreduction.toml#e_grave": {
				"ar": "È + مفتاح Y يصحح 2 SFBs: èy = aî و yè = â",
				"cs": "È + klávesa Y opravuje 2 SFBs: èy = aî a yè = â",
				"da": "È + Y-tast retter 2 SFBs: èy = aî og yè = â",
				"de": "È + Y-Taste korrigiert 2 SFBs: èy = aî und yè = â",
				"en": "È + Y key fixes 2 SFBs: èy = aî and yè = â",
				"es": "È + tecla Y corrige 2 SFBs: èy = aî y yè = â",
				"fr": "È + touche Y corrige 2 SFBs : èy = aî et yè = â",
				"he": "È + מקש Y מתקן 2 SFBs: èy = aî ו-yè = â",
				"hi": "È + Y कुंजी 2 SFBs ठीक करती है: èy = aî और yè = â",
				"it": "È + tasto Y corregge 2 SFBs: èy = aî e yè = â",
				"ja": "È + Yキーが2つのSFBを修正：èy = aî、yè = â",
				"ko": "È + Y키가 2개의 SFB를 수정: èy = aî 및 yè = â",
				"nl": "È + Y-toets corrigeert 2 SFBs: èy = aî en yè = â",
				"no": "È + Y-tast retter 2 SFBs: èy = aî og yè = â",
				"pl": "È + klawisz Y poprawia 2 SFBs: èy = aî i yè = â",
				"pt": "È + tecla Y corrige 2 SFBs: èy = aî e yè = â",
				"ru": "È + клавиша Y исправляет 2 SFBs: èy = aî и yè = â",
				"sv": "È + Y-tangent rättar 2 SFBs: èy = aî och yè = â",
				"tr": "È + Y tuşu 2 SFBs düzeltir: èy = aî ve yè = â",
				"uk": "È + клавіша Y виправляє 2 SFBs: èy = aî та yè = â",
				"zh": "È + Y 键修正 2 个 SFB：èy = aî 和 yè = â"
			},
			"layouts/registry/ergopti/hotstrings/sfbsreduction.toml#bu": {
				"ar": "À + ★/U يصحح 2 SFBs: à★ = bu و àu = ub",
				"cs": "À + ★/U opravuje 2 SFBs: à★ = bu a àu = ub",
				"da": "À + ★/U retter 2 SFBs: à★ = bu og àu = ub",
				"de": "À + ★/U korrigiert 2 SFBs: à★ = bu und àu = ub",
				"en": "À + ★/U fixes 2 SFBs: à★ = bu and àu = ub",
				"es": "À + ★/U corrige 2 SFBs: à★ = bu y àu = ub",
				"fr": "À + ★/U corrige 2 SFBs : à★ = bu et àu = ub",
				"he": "À + ★/U מתקן 2 SFBs: à★ = bu ו-àu = ub",
				"hi": "À + ★/U 2 SFBs ठीक करता है: à★ = bu और àu = ub",
				"it": "À + ★/U corregge 2 SFBs: à★ = bu e àu = ub",
				"ja": "À + ★/U が2つのSFBを修正：à★ = bu、àu = ub",
				"ko": "À + ★/U가 2개의 SFB를 수정: à★ = bu 및 àu = ub",
				"nl": "À + ★/U corrigeert 2 SFBs: à★ = bu en àu = ub",
				"no": "À + ★/U retter 2 SFBs: à★ = bu og àu = ub",
				"pl": "À + ★/U poprawia 2 SFBs: à★ = bu i àu = ub",
				"pt": "À + ★/U corrige 2 SFBs: à★ = bu e àu = ub",
				"ru": "À + ★/U исправляет 2 SFBs: à★ = bu и àu = ub",
				"sv": "À + ★/U rättar 2 SFBs: à★ = bu och àu = ub",
				"tr": "À + ★/U 2 SFBs düzeltir: à★ = bu ve àu = ub",
				"uk": "À + ★/U виправляє 2 SFBs: à★ = bu та àu = ub",
				"zh": "À + ★/U 修正 2 个 SFB：à★ = bu 和 àu = ub"
			},
			"layouts/registry/ergopti/hotstrings/sfbsreduction.toml#i_e_acute": {
				"ar": "À + É يصحح 2 SFBs: éà = ié و àé = éi",
				"cs": "À + É opravuje 2 SFBs: éà = ié a àé = éi",
				"da": "À + É retter 2 SFBs: éà = ié og àé = éi",
				"de": "À + É korrigiert 2 SFBs: éà = ié und àé = éi",
				"en": "À + É fixes 2 SFBs: éà = ié and àé = éi",
				"es": "À + É corrige 2 SFBs: éà = ié y àé = éi",
				"fr": "À + É corrige 2 SFBs : éà = ié et àé = éi",
				"he": "À + É מתקן 2 SFBs: éà = ié ו-àé = éi",
				"hi": "À + É 2 SFBs ठीक करता है: éà = ié और àé = éi",
				"it": "À + É corregge 2 SFBs: éà = ié e àé = éi",
				"ja": "À + É が2つのSFBを修正：éà = ié、àé = éi",
				"ko": "À + É가 2개의 SFB를 수정: éà = ié 및 àé = éi",
				"nl": "À + É corrigeert 2 SFBs: éà = ié en àé = éi",
				"no": "À + É retter 2 SFBs: éà = ié og àé = éi",
				"pl": "À + É poprawia 2 SFBs: éà = ié i àé = éi",
				"pt": "À + É corrige 2 SFBs: éà = ié e àé = éi",
				"ru": "À + É исправляет 2 SFBs: éà = ié и àé = éi",
				"sv": "À + É rättar 2 SFBs: éà = ié och àé = éi",
				"tr": "À + É 2 SFBs düzeltir: éà = ié ve àé = éi",
				"uk": "À + É виправляє 2 SFBs: éà = ié та àé = éi",
				"zh": "À + É 修正 2 个 SFB：éà = ié 和 àé = éi"
			},
			"layouts/registry/ergopti/hotstrings/rolls.toml": {
				"ar": "تداول",
				"cs": "Rolování",
				"da": "Rolls",
				"de": "Läufe",
				"en": "Rolls",
				"es": "Rodamientos",
				"fr": "Roulements",
				"he": "גלגולים",
				"hi": "रोल्स",
				"it": "Rollate",
				"ja": "ロール",
				"ko": "롤",
				"nl": "Rolls",
				"no": "Rolls",
				"pl": "Rolady",
				"pt": "Rolagens",
				"ru": "Перекаты",
				"sv": "Rolls",
				"tr": "Yuvarlamalar",
				"uk": "Перекати",
				"zh": "连击"
			},
			"hotstrings/french/autocorrection.toml": {
				"ar": "تصحيح تلقائي",
				"cs": "Automatická oprava",
				"da": "Autokorrektur",
				"de": "Autokorrektur",
				"en": "Autocorrection",
				"es": "Autocorrección",
				"fr": "Autocorrection",
				"he": "תיקון אוטומטי",
				"hi": "स्वत: सुधार",
				"it": "Correzione automatica",
				"ja": "自動修正",
				"ko": "자동 수정",
				"nl": "Autocorrectie",
				"no": "Autokorrektur",
				"pl": "Autokorekta",
				"pt": "Autocorreção",
				"ru": "Автокоррекция",
				"sv": "Autokorrigering",
				"tr": "Otomatik düzeltme",
				"uk": "Автовиправлення",
				"zh": "自动纠错"
			},
			"hotstrings/french/autocorrection.toml#accents": {
				"ar": "تصحيح تلقائي للتشكيل لعدد كبير من الكلمات",
				"cs": "Automatická oprava akcentů pro velké množství slov",
				"da": "Accent-autokorrektur for et stort antal ord",
				"de": "Akzent-Autokorrektur für sehr viele Wörter",
				"en": "Accent autocorrection for a large number of words",
				"es": "Autocorrección de acentos de muchísimas palabras",
				"fr": "Autocorrection des accents de très nombreux mots",
				"he": "תיקון אוטומטי של ניקוד למספר רב של מילים",
				"hi": "बहुत सारे शब्दों के लिए स्वर चिह्न स्वत: सुधार",
				"it": "Autocorrezione accenti per moltissime parole",
				"ja": "多数の単語のアクセント自動修正",
				"ko": "많은 단어의 액센트 자동 수정",
				"nl": "Accentautocorrectie voor een groot aantal woorden",
				"no": "Aksentatokorrektur for et stort antall ord",
				"pl": "Autokorekta akcentów dla dużej liczby słów",
				"pt": "Autocorreção de acentos para muitas palavras",
				"ru": "Автокоррекция ударений для большого числа слов",
				"sv": "Accentautokorrigering för ett stort antal ord",
				"tr": "Çok sayıda kelime için otomatik aksan düzeltme",
				"uk": "Автовиправлення наголосів для великої кількості слів",
				"zh": "对大量单词进行重音自动更正"
			},
			"hotstrings/french/autocorrection.toml#names": {
				"ar": "تصحيح تلقائي للتشكيل في الأسماء وأسماء الدول: alexei = Alexeï, taiwan = Taïwan, …",
				"cs": "Automatická oprava akcentů ve jménech a názvech zemí: alexei = Alexeï, taiwan = Taïwan, …",
				"da": "Aksentautokorrektur for fornavne og landenavne: alexei = Alexeï, taiwan = Taïwan, …",
				"de": "Akzent-Autokorrektur für Vornamen und Ländernamen: alexei = Alexeï, taiwan = Taïwan, …",
				"en": "Accent autocorrection for first names and country names: alexei = Alexeï, taiwan = Taïwan, …",
				"es": "Autocorrección de acentos en nombres de pila y de países: alexei = Alexeï, taiwan = Taïwan, …",
				"fr": "Autocorrection des accents sur les prénoms et les noms de pays : alexei = Alexeï, taiwan = Taïwan, …",
				"he": "תיקון אוטומטי של ניקוד בשמות פרטיים ושמות מדינות: alexei = Alexeï, taiwan = Taïwan, …",
				"hi": "नाम और देश के नामों में उच्चारण चिह्न स्वत: सुधार: alexei = Alexeï, taiwan = Taïwan, …",
				"it": "Autocorrezione accenti in nomi di battesimo e nomi di paese: alexei = Alexeï, taiwan = Taïwan, …",
				"ja": "名前と国名のアクセント自動修正：alexei = Alexeï, taiwan = Taïwan, …",
				"ko": "이름과 국가명의 액센트 자동 수정: alexei = Alexeï, taiwan = Taïwan, …",
				"nl": "Accentautocorrectie voor voornamen en landnamen: alexei = Alexeï, taiwan = Taïwan, …",
				"no": "Aksentatokorrektur for fornavn og landsnavn: alexei = Alexeï, taiwan = Taïwan, …",
				"pl": "Autokorekta akcentów w imionach i nazwach krajów: alexei = Alexeï, taiwan = Taïwan, …",
				"pt": "Autocorreção de acentos em nomes próprios e nomes de países: alexei = Alexeï, taiwan = Taïwan, …",
				"ru": "Автокоррекция ударений в именах и названиях стран: alexei = Alexeï, taiwan = Taïwan, …",
				"sv": "Accentautokorrigering för förnamn och landsnamn: alexei = Alexeï, taiwan = Taïwan, …",
				"tr": "İsimler ve ülke adlarında otomatik aksan düzeltme: alexei = Alexeï, taiwan = Taïwan, …",
				"uk": "Автовиправлення наголосів у іменах та назвах країн: alexei = Alexeï, taiwan = Taïwan, …",
				"zh": "人名和国名的重音自动更正：alexei = Alexeï，taiwan = Taïwan，…"
			},
			"hotstrings/french/autocorrection.toml#typographic_apostrophe": {
				"ar": "تصبح الفاصلة العليا طباعية عند كتابة النص: m’a = m’a, it’s = it’s, …",
				"cs": "Apostrof se při psaní textu stává typografickým: m’a = m’a, it’s = it’s, …",
				"da": "Apostrof bliver typografisk ved tekstskrivning: m’a = m’a, it’s = it’s, …",
				"de": "Apostroph wird beim Schreiben typografisch: m’a = m’a, it’s = it’s, …",
				"en": "Apostrophe becomes typographic while typing text: m’a = m’a, it’s = it’s, …",
				"es": "El apóstrofo se vuelve tipográfico al escribir texto: m’a = m’a, it’s = it’s, …",
				"fr": "L’apostrophe devient typographique lors de l’écriture de texte : m’a = m’a, it’s = it’s, …",
				"he": "הגרש הופך לטיפוגרפי בעת כתיבת טקסט: m’a = m’a, it’s = it’s, …",
				"hi": "टेक्स्ट लिखते समय एपॉस्ट्रोफी टाइपोग्राफिक हो जाती है: m’a = m’a, it’s = it’s, …",
				"it": "L’apostrofo diventa tipografico durante la scrittura del testo: m’a = m’a, it’s = it’s, …",
				"ja": "テキスト入力中にアポストロフィが活版印刷体になる：m’a = m’a, it’s = it’s, …",
				"ko": "텍스트 입력 시 아포스트로피가 인쇄체로 변환: m’a = m’a, it’s = it’s, …",
				"nl": "Apostrof wordt typografisch bij het schrijven van tekst: m’a = m’a, it’s = it’s, …",
				"no": "Apostrof blir typografisk ved skriving av tekst: m’a = m’a, it’s = it’s, …",
				"pl": "Apostrof staje się typograficzny podczas pisania tekstu: m’a = m’a, it’s = it’s, …",
				"pt": "O apóstrofo torna-se tipográfico ao escrever texto: m’a = m’a, it’s = it’s, …",
				"ru": "Апостроф становится типографским при наборе текста: m’a = m’a, it’s = it’s, …",
				"sv": "Apostrof blir typografisk vid textskrivning: m’a = m’a, it’s = it’s, …",
				"tr": "Metin yazarken kesme işareti tipografik hale gelir: m’a = m’a, it’s = it’s, …",
				"uk": "Апостроф стає типографічним під час написання тексту: m’a = m’a, it’s = it’s, …",
				"zh": "书写时撇号变为印刷体：m’a = m’a，it’s = it’s，…"
			},
			"hotstrings/french/autocorrection.toml#errors": {
				"ar": "تصحيح بعض أخطاء الكتابة: OUi = Oui, aeu = eau, …",
				"cs": "Oprava určitých překlepů: OUi = Oui, aeu = eau, …",
				"da": "Korrektion af visse stavefejl: OUi = Oui, aeu = eau, …",
				"de": "Korrektur bestimmter Tippfehler: OUi = Oui, aeu = eau, …",
				"en": "Correction of certain typos: OUi = Oui, aeu = eau, …",
				"es": "Corrección de ciertos errores tipográficos: OUi = Oui, aeu = eau, …",
				"fr": "Correction de certaines fautes de frappe : OUi = Oui, aeu = eau, …",
				"he": "תיקון שגיאות הקלדה מסוימות: OUi = Oui, aeu = eau, …",
				"hi": "कुछ टाइपो सुधार: OUi = Oui, aeu = eau, …",
				"it": "Correzione di certi errori di battitura: OUi = Oui, aeu = eau, …",
				"ja": "特定のタイポを修正：OUi = Oui, aeu = eau, …",
				"ko": "특정 오타 수정: OUi = Oui, aeu = eau, …",
				"nl": "Correctie van bepaalde typefouten: OUi = Oui, aeu = eau, …",
				"no": "Korreksjon av visse skrivefeil: OUi = Oui, aeu = eau, …",
				"pl": "Korekcja niektórych literówek: OUi = Oui, aeu = eau, …",
				"pt": "Correcção de certos erros de digitação: OUi = Oui, aeu = eau, …",
				"ru": "Исправление некоторых опечаток: OUi = Oui, aeu = eau, …",
				"sv": "Korrigering av vissa skrivfel: OUi = Oui, aeu = eau, …",
				"tr": "Belirli yazım hatalarının düzeltilmesi: OUi = Oui, aeu = eau, …",
				"uk": "Виправлення певних друкарських помилок: OUi = Oui, aeu = eau, …",
				"zh": "纠正某些打字错误：OUi = Oui，aeu = eau，…"
			},
			"hotstrings/french/autocorrection.toml#ou": {
				"ar": "كتابة [où ] ثم نقطة أو فاصلة تحذف تلقائياً المسافة المضافة مسبقاً",
				"cs": "Psaní [où ] a pak tečky nebo čárky automaticky odstraní dříve přidanou mezeru",
				"da": "Tastning af [où ] efterfulgt af punktum eller komma fjerner automatisk det tidligere tilføjede mellemrum",
				"de": "Tippen von [où ] gefolgt von Punkt oder Komma entfernt automatisch das zuvor eingefügte Leerzeichen",
				"en": "Typing [où ] then a period or comma automatically removes the previously added space",
				"es": "Escribir [où ] y luego un punto o coma elimina automáticamente el espacio añadido",
				"fr": "Taper [où ] puis un point ou une virgule supprime automatiquement l’espace ajouté avant",
				"he": "הקלדת [où ] ואחריה נקודה או פסיק מוחקת אוטומטית את הרווח שנוסף קודם",
				"hi": "[où ] टाइप करने के बाद पूर्णविराम या अल्पविराम पहले जोड़ी गई स्पेस अपने आप हटा देता है",
				"it": "Digitare [où ] poi un punto o virgola rimuove automaticamente lo spazio precedentemente aggiunto",
				"ja": "[où ] を入力後にピリオドやカンマを入力すると、前に追加されたスペースが自動的に削除される",
				"ko": "[où ]를 입력한 후 마침표나 쉼표를 입력하면 이전에 추가된 공백이 자동으로 제거됨",
				"nl": "Het typen van [où ] gevolgd door een punt of komma verwijdert automatisch de eerder toegevoegde spatie",
				"no": "Tastning av [où ] etterfulgt av punktum eller komma fjerner automatisk det tidligere tillagte mellomrommet",
				"pl": "Wpisanie [où ] a następnie kropki lub przecinka automatycznie usuwa wcześniej dodaną spację",
				"pt": "Escrever [où ] e depois um ponto ou vírgula remove automaticamente o espaço adicionado anteriormente",
				"ru": "Ввод [où ] и затем точки или запятой автоматически удаляет ранее добавленный пробел",
				"sv": "Att skriva [où ] följt av punkt eller komma tar automatiskt bort det tidigare tillagda mellanslagets",
				"tr": "[où ] yazıp ardından nokta veya virgül yazmak önceden eklenen boşluğu otomatik olarak kaldırır",
				"uk": "Введення [où ] а потім крапки чи коми автоматично видаляє раніше додану пробіл",
				"zh": "输入 [où ] 后接句号或逗号，自动删除前面添加的空格"
			},
			"hotstrings/french/autocorrection.toml#multiple_punctuation_marks": {
				"ar": "كتابة \"!\" أو \"?\" مرات متعددة لا تضيف مسافة غير قابلة للكسر بين الأحرف",
				"cs": "Opakované psaní \"!\" nebo \"?\" nevkládá nezalomitelnou mezeru mezi znaky",
				"da": "Gentagen tastning af \"!\" eller \"?\" indsætter ikke et ikke-brydende mellemrum mellem hvert tegn",
				"de": "Mehrfaches Tippen von \"!\" oder \"?\" fügt kein geschütztes Leerzeichen zwischen die Zeichen ein",
				"en": "Typing \"!\" or \"?\" multiple times in a row does not insert a non-breaking space between each character",
				"es": "Escribir \"!\" o \"?\" varias veces seguidas no añade espacio de no separación entre cada carácter",
				"fr": "Taper \"!\" ou \"?\" plusieurs fois d’affilée n’ajoute pas d’espace insécable entre chaque caractère",
				"he": "הקלדת \"!\" או \"?\" מספר פעמים לא מוסיפה רווח קשיח בין כל תו",
				"hi": "\"!\" या \"?\" को कई बार टाइप करने पर प्रत्येक वर्ण के बीच नॉन-ब्रेकिंग स्पेस नहीं जुड़ती",
				"it": "Digitare \"!\" o \"?\" più volte di fila non aggiunge spazio non divisibile tra ogni carattere",
				"ja": "\"!\" や \"?\" を連続入力しても各文字間にノーブレークスペースは挿入されない",
				"ko": "\"!\" 또는 \"?\"를 여러 번 연속 입력해도 각 문자 사이에 줄바꿈 없는 공백이 삽입되지 않음",
				"nl": "Meerdere malen \"!\" of \"?\" typen voegt geen vaste spatie in tussen elk teken",
				"no": "Gjentatt skriving av \"!\" eller \"?\" setter ikke inn et ikke-brytende mellomrom mellom hvert tegn",
				"pl": "Wielokrotne pisanie \"!\" lub \"?\" nie wstawia niełamalnej spacji między każdy znak",
				"pt": "Escrever \"!\" ou \"?\" várias vezes seguidas não adiciona espaço não separável entre cada carácter",
				"ru": "Многократный ввод \"!\" или \"?\" не вставляет неразрывный пробел между символами",
				"sv": "Upprepat skrivande av \"!\" eller \"?\" infogar inte ett hårt mellanslag mellan varje tecken",
				"tr": "\"!\" veya \"?\" karakterini arka arkaya birden fazla yazmak karakterler arasına bölünemez boşluk eklemez",
				"uk": "Багаторазовий ввід \"!\" або \"?\" не вставляє нерозривний пробіл між кожним символом",
				"zh": "连续输入 \"!\" 或 \"?\" 不会在每个字符间插入不间断空格"
			},
			"hotstrings/french/autocorrection.toml#suffixes_a_chaining": {
				"ar": "تسلسل عدة لواحق، مثل aim|able|ement = aimablement",
				"cs": "Řetězit více přípon, např. aim|able|ement = aimablement",
				"da": "Kæde flere suffikser, f.eks. aim|able|ement = aimablement",
				"de": "Mehrere Suffixe verketten, z.B. aim|able|ement = aimablement",
				"en": "Chain multiple suffixes, e.g. aim|able|ement = aimablement",
				"es": "Encadenar varios sufijos, como aim|able|ement = aimablement",
				"fr": "Enchaîner plusieurs fois des suffixes, comme aim|able|ement = aimablement",
				"he": "שרשור מספר סיומות, למשל aim|able|ement = aimablement",
				"hi": "कई प्रत्ययों को क्रमबद्ध करें, जैसे aim|able|ement = aimablement",
				"it": "Concatenare più suffissi, come aim|able|ement = aimablement",
				"ja": "複数のサフィックスを連鎖させる（例：aim|able|ement = aimablement）",
				"ko": "여러 접미사 연결, 예: aim|able|ement = aimablement",
				"nl": "Meerdere achtervoegsels aan elkaar koppelen, bijv. aim|able|ement = aimablement",
				"no": "Kjede flere suffikser, f.eks. aim|able|ement = aimablement",
				"pl": "Łączyć wiele sufiksów, np. aim|able|ement = aimablement",
				"pt": "Encadear vários sufixos, como aim|able|ement = aimablement",
				"ru": "Цепочка нескольких суффиксов, напр. aim|able|ement = aimablement",
				"sv": "Kedja flera suffix, t.ex. aim|able|ement = aimablement",
				"tr": "Birden fazla son ek zincirlemek, örn. aim|able|ement = aimablement",
				"uk": "Ланцюжок кількох суфіксів, напр. aim|able|ement = aimablement",
				"zh": "连接多个后缀，如 aim|able|ement = aimablement"
			},
			"hotstrings/french/autocorrection.toml#minus": {
				"ar": "يتجنب كتابة الواصلات: aije = ai-je, atil = a-t-il, …",
				"cs": "Vyhýbá se psaní pomlček: aije = ai-je, atil = a-t-il, …",
				"da": "Undgår at skrive bindestreger: aije = ai-je, atil = a-t-il, …",
				"de": "Vermeidet das Tippen von Bindestrichen: aije = ai-je, atil = a-t-il, …",
				"en": "Avoids typing hyphens: aije = ai-je, atil = a-t-il, …",
				"es": "Evita escribir guiones: aije = ai-je, atil = a-t-il, …",
				"fr": "Évite de devoir taper des tirets : aije = ai-je, atil = a-t-il, …",
				"he": "מונע הקלדת מקפים: aije = ai-je, atil = a-t-il, …",
				"hi": "हाइफ़न टाइप करने से बचाता है: aije = ai-je, atil = a-t-il, …",
				"it": "Evita di dover digitare trattini: aije = ai-je, atil = a-t-il, …",
				"ja": "ハイフン入力を避ける：aije = ai-je, atil = a-t-il, …",
				"ko": "하이픈 입력 방지: aije = ai-je, atil = a-t-il, …",
				"nl": "Vermijdt het typen van koppeltekens: aije = ai-je, atil = a-t-il, …",
				"no": "Unngår å skrive bindestreker: aije = ai-je, atil = a-t-il, …",
				"pl": "Unika wpisywania myślników: aije = ai-je, atil = a-t-il, …",
				"pt": "Evita ter de escrever hífens: aije = ai-je, atil = a-t-il, …",
				"ru": "Избегает ввода дефисов: aije = ai-je, atil = a-t-il, …",
				"sv": "Undviker att skriva bindestreck: aije = ai-je, atil = a-t-il, …",
				"tr": "Kısa çizgi yazmaktan kaçınır: aije = ai-je, atil = a-t-il, …",
				"uk": "Уникає введення дефісів: aije = ai-je, atil = a-t-il, …",
				"zh": "避免输入连字符：aije = ai-je，atil = a-t-il，…"
			},
			"hotstrings/french/autocorrection.toml#minus_apostrophe": {
				"ar": "الفاصلة العليا تعمل كواصلة: ai’je = ai-je, a’t’il = a-t-il, …",
				"cs": "Apostrof funguje jako pomlčka: ai’je = ai-je, a’t’il = a-t-il, …",
				"da": "Apostrof fungerer som bindestreg: ai’je = ai-je, a’t’il = a-t-il, …",
				"de": "Apostroph wirkt als Bindestrich: ai’je = ai-ge, a’t’il = a-t-il, …",
				"en": "Apostrophe acts as a hyphen: ai’je = ai-je, a’t’il = a-t-il, …",
				"es": "El apóstrofo actúa como guion: ai’je = ai-je, a’t’il = a-t-il, …",
				"fr": "L’apostrophe agit comme un tiret : ai’je = ai-je, a’t’il = a-t-il, …",
				"he": "גרש פועל כמקף: ai’je = ai-je, a’t’il = a-t-il, …",
				"hi": "एपॉस्ट्रोफी हाइफ़न की तरह काम करती है: ai’je = ai-je, a’t’il = a-t-il, …",
				"it": "L’apostrofo funge da trattino: ai’je = ai-je, a’t’il = a-t-il, …",
				"ja": "アポストロフィがハイフンとして機能：ai’je = ai-je, a’t’il = a-t-il, …",
				"ko": "아포스트로피가 하이픈 역할: ai’je = ai-je, a’t’il = a-t-il, …",
				"nl": "Apostrof fungeert als koppelteken: ai’je = ai-je, a’t’il = a-t-il, …",
				"no": "Apostrof fungerer som bindestrek: ai’je = ai-je, a’t’il = a-t-il, …",
				"pl": "Apostrof działa jako myślnik: ai’je = ai-je, a’t’il = a-t-il, …",
				"pt": "O apóstrofo funciona como hífen: ai’je = ai-je, a’t’il = a-t-il, …",
				"ru": "Апостроф действует как дефис: ai’je = ai-je, a’t’il = a-t-il, …",
				"sv": "Apostrof fungerar som bindestreck: ai’je = ai-je, a’t’il = a-t-il, …",
				"tr": "Kesme işareti kısa çizgi gibi davranır: ai’je = ai-je, a’t’il = a-t-il, …",
				"uk": "Апостроф діє як дефіс: ai’je = ai-je, a’t’il = a-t-il, …",
				"zh": "撇号充当连字符：ai’je = ai-je，a’t’il = a-t-il，…"
			},
			"hotstrings/french/magickey.toml": {
				"ar": "مفتاح ★ وتوسيع النص",
				"cs": "Klávesa ★ a rozšíření textu",
				"da": "★-tast og tekstudvidelse",
				"de": "★-Taste und Texterweiterung",
				"en": "★ key and text expansion",
				"es": "Tecla ★ y expansión de texto",
				"fr": "Touche ★ et expansion de texte",
				"he": "מקש ★ והרחבת טקסט",
				"hi": "★ कुंजी और टेक्स्ट विस्तार",
				"it": "Tasto ★ e espansione testo",
				"ja": "★キーとテキスト展開",
				"ko": "★ 키와 텍스트 확장",
				"nl": "★-toets en tekstuitbreiding",
				"no": "★-tast og tekstutvidelse",
				"pl": "Klawisz ★ i rozszerzenie tekstu",
				"pt": "Tecla ★ e expansão de texto",
				"ru": "Клавиша ★ и расширение текста",
				"sv": "★-tangent och textutvidgning",
				"tr": "★ tuşu ve metin genişletme",
				"uk": "Клавіша ★ та розширення тексту",
				"zh": "★ 键与文本扩展"
			},
			"hotstrings/french/magickey.toml#text_expansion": {
				"ar": "توسيع النص: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"cs": "Rozšíření textu: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"da": "Tekstudvidelse: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"de": "Texterweiterung: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"en": "Text expansion: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"es": "Expansión de texto: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"fr": "Expansion de texte : c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"he": "הרחבת טקסט: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"hi": "टेक्स्ट विस्तार: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"it": "Espansione testo: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"ja": "テキスト展開：c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"ko": "텍스트 확장: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"nl": "Tekstuitbreiding: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"no": "Tekstutvidelse: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"pl": "Rozszerzenie tekstu: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"pt": "Expansão de texto: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"ru": "Расширение текста: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"sv": "Textutvidgning: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"tr": "Metin genişletme: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"uk": "Розширення тексту: c★ = c’est, gt★ = j’étais, pex★ = par exemple, …",
				"zh": "文本扩展：c★ = c’est，gt★ = j’étais，pex★ = par exemple，…"
			},
			"hotstrings/french/magickey.toml#text_expansion_auto": {
				"ar": "توسيع النص التلقائي (بدون مفتاح ★): ju' = jusqu’, ya = y’a",
				"cs": "Automatické rozšíření textu (bez klávesy ★): ju' = jusqu’, ya = y’a",
				"da": "Automatisk tekstudvidelse (uden ★-tasten): ju' = jusqu’, ya = y’a",
				"de": "Automatische Texterweiterung (ohne die ★-Taste): ju' = jusqu’, ya = y’a",
				"en": "Automatic text expansion (without the ★ key): ju' = jusqu’, ya = y’a",
				"es": "Expansión de texto automática (sin la tecla ★): ju' = jusqu’, ya = y’a",
				"fr": "Expansion de texte automatique (sans la touche ★) : ju' = jusqu’, ya = y’a",
				"he": "הרחבת טקסט אוטומטית (ללא מקש ★): ju' = jusqu’, ya = y’a",
				"hi": "स्वचालित टेक्स्ट विस्तार (★ कुंजी के बिना): ju' = jusqu’, ya = y’a",
				"it": "Espansione testo automatica (senza il tasto ★): ju' = jusqu’, ya = y’a",
				"ja": "自動テキスト展開（★キー不要）：ju' = jusqu’, ya = y’a",
				"ko": "자동 텍스트 확장 (★ 키 없이): ju' = jusqu’, ya = y’a",
				"nl": "Automatische tekstuitbreiding (zonder de ★-toets): ju' = jusqu’, ya = y’a",
				"no": "Automatisk tekstutvidelse (uten ★-tasten): ju' = jusqu’, ya = y’a",
				"pl": "Automatyczne rozszerzenie tekstu (bez klawisza ★): ju' = jusqu’, ya = y’a",
				"pt": "Expansão de texto automática (sem a tecla ★): ju' = jusqu’, ya = y’a",
				"ru": "Автоматическое расширение текста (без клавиши ★): ju' = jusqu’, ya = y’a",
				"sv": "Automatisk textutvidgning (utan ★-tangenten): ju' = jusqu’, ya = y’a",
				"tr": "Otomatik metin genişletme (★ tuşu olmadan): ju' = jusqu’, ya = y’a",
				"uk": "Автоматичне розширення тексту (без клавіші ★): ju' = jusqu’, ya = y’a",
				"zh": "自动文本扩展（无需 ★ 键）：ju' = jusqu’，ya = y’a"
			},
			"hotstrings/french/magickey.toml#text_expansion_emojis": {
				"ar": "توسيع النص بالإيموجي: voiture★ = 🚗, koala★ = 🐨, …",
				"cs": "Emoji rozšíření textu: voiture★ = 🚗, koala★ = 🐨, …",
				"da": "Emoji tekstudvidelse: voiture★ = 🚗, koala★ = 🐨, …",
				"de": "Emoji-Texterweiterung: voiture★ = 🚗, koala★ = 🐨, …",
				"en": "Emoji text expansion: voiture★ = 🚗, koala★ = 🐨, …",
				"es": "Expansión de texto con emojis: voiture★ = 🚗, koala★ = 🐨, …",
				"fr": "Expansion de texte Emojis : voiture★ = 🚗, koala★ = 🐨, …",
				"he": "הרחבת טקסט אמוג'י: voiture★ = 🚗, koala★ = 🐨, …",
				"hi": "इमोजी टेक्स्ट विस्तार: voiture★ = 🚗, koala★ = 🐨, …",
				"it": "Espansione testo emoji: voiture★ = 🚗, koala★ = 🐨, …",
				"ja": "絵文字テキスト展開：voiture★ = 🚗, koala★ = 🐨, …",
				"ko": "이모지 텍스트 확장: voiture★ = 🚗, koala★ = 🐨, …",
				"nl": "Emoji tekstuitbreiding: voiture★ = 🚗, koala★ = 🐨, …",
				"no": "Emoji tekstutvidelse: voiture★ = 🚗, koala★ = 🐨, …",
				"pl": "Rozszerzenie tekstu emoji: voiture★ = 🚗, koala★ = 🐨, …",
				"pt": "Expansão de texto emoji: voiture★ = 🚗, koala★ = 🐨, …",
				"ru": "Расширение текста эмодзи: voiture★ = 🚗, koala★ = 🐨, …",
				"sv": "Emoji textutvidgning: voiture★ = 🚗, koala★ = 🐨, …",
				"tr": "Emoji metin genişletme: voiture★ = 🚗, koala★ = 🐨, …",
				"uk": "Розширення тексту емодзі: voiture★ = 🚗, koala★ = 🐨, …",
				"zh": "表情文本扩展：voiture★ = 🚗，koala★ = 🐨，…"
			}
		},
		"platforms": {
			"windows": {
				"manifest_platform": "ahk",
				"pages": [
					{
						"id": "tap_holds",
						"title_key": "menu.tapholds.title",
						"question_key": "menu.tapholds.enable",
						"description_key": "onboarding.page.tap_holds.description",
						"consent": false,
						"groups": [
							{
								"label": [
									{
										"key": "menu.tapholds.left_hand_tap_hold"
									}
								],
								"items": [
									{
										"path": "tap_holds.keys.tab",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "tab",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.tab"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.alt_tab_monitor"
														}
													],
													[
														{
															"key": "tap_hold.hold.alt"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.caps_lock",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "caps_lock",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.caps_lock"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.enter"
														}
													],
													[
														{
															"key": "tap_hold.hold.ctrl"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.left_shift",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "left_shift",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.left_shift"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.copy"
														}
													],
													[
														{
															"key": "tap_hold.hold.shift"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.left_ctrl",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "left_ctrl",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.left_ctrl"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.paste"
														}
													],
													[
														{
															"key": "tap_hold.hold.ctrl"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.left_alt",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "left_alt",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.left_alt"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.backspace"
														}
													],
													[
														{
															"key": "tap_hold.hold.nav_layer"
														}
													]
												]
											}
										]
									}
								]
							},
							{
								"label": [
									{
										"key": "menu.tapholds.right_hand_tap_hold"
									}
								],
								"items": [
									{
										"path": "tap_holds.keys.alt_gr",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "alt_gr",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.alt_gr"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.tab"
														}
													],
													[
														{
															"key": "tap_hold.hold.alt_gr"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.right_ctrl",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "right_ctrl",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.right_ctrl"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.one_shot_shift"
														}
													],
													[
														{
															"key": "tap_hold.hold.shift"
														}
													]
												]
											}
										]
									}
								]
							}
						],
						"master": {
							"path": "category_enabled.tap_holds",
							"default": false
						}
					},
					{
						"id": "shortcuts",
						"title_key": "menu.shortcuts.title",
						"question_key": "menu.shortcuts.enable",
						"description_key": "onboarding.page.shortcuts.description",
						"consent": false,
						"groups": [
							{
								"items": [
									{
										"path": "shortcuts.get_hex_value",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.gethexvalue"
											}
										]
									},
									{
										"path": "shortcuts.gpt.enabled",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.gpt"
											}
										]
									},
									{
										"path": "shortcuts.search.enabled",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.search"
											}
										]
									},
									{
										"path": "shortcuts.take_note.enabled",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.takenote"
											}
										]
									},
									{
										"path": "shortcuts.microsoft_bold",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.microsoftbold"
											}
										]
									},
									{
										"path": "shortcuts.title_case",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.titlecase"
											}
										]
									},
									{
										"path": "shortcuts.uppercase",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.uppercase"
											}
										]
									},
									{
										"path": "shortcuts.select_line",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "sg_actions.select_line"
											}
										]
									},
									{
										"path": "shortcuts.spotlight_mouse",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.spotlightmouse"
											}
										]
									},
									{
										"path": "shortcuts.surround_with_parentheses",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.surroundwithparentheses"
											}
										]
									},
									{
										"path": "shortcuts.teleport_mouse",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.teleportmouse"
											}
										]
									},
									{
										"path": "shortcuts.wrap_text_if_selected",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.label_wrap_text"
											}
										]
									},
									{
										"path": "shortcuts.open_downloads",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.opendownloads"
											}
										]
									},
									{
										"path": "shortcuts.move",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.move"
											}
										]
									},
									{
										"path": "shortcuts.screen",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.screen"
											}
										]
									},
									{
										"path": "shortcuts.win_caps_lock",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.wincapslock"
											}
										]
									},
									{
										"path": "shortcuts.a_grave.enabled",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.agrave"
											}
										]
									},
									{
										"path": "shortcuts.e_acute.enabled",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.eacute"
											}
										]
									},
									{
										"path": "shortcuts.e_circ.enabled",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.ecirc"
											}
										]
									},
									{
										"path": "shortcuts.e_grave.enabled",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.egrave"
											}
										]
									},
									{
										"path": "shortcuts.key_combination_taps.alt_gr_then_left_alt",
										"value": "ctrl_backspace",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "tap_hold.group.alt_gr"
											},
											{
												"text": " + "
											},
											{
												"key": "tap_hold.group.left_alt"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.ctrl_backspace"
											}
										]
									},
									{
										"path": "shortcuts.key_combination_taps.alt_gr_then_caps_lock",
										"value": "ctrl_delete",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "tap_hold.group.alt_gr"
											},
											{
												"text": " + "
											},
											{
												"key": "tap_hold.group.caps_lock"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.ctrl_delete"
											}
										]
									},
									{
										"path": "shortcuts.key_combination_taps.left_alt_then_caps_lock",
										"value": "caps_word",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "tap_hold.group.left_alt"
											},
											{
												"text": " + "
											},
											{
												"key": "tap_hold.group.caps_lock"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.caps_word"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.ctrl_b",
										"value": "microsoft_bold",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + B"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.microsoft_bold"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.ctrl_shift_v",
										"value": "paste_plain",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + Shift + V"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.paste_plain"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_a",
										"value": "select_line",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + A"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.select_line"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_g",
										"value": "open_url",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + G"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.open_url"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_h",
										"value": "screen_capture",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + H"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.screen_capture"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_m",
										"value": "activity_simulation",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + M"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.activity_simulation"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_n",
										"value": "take_note",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + N"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.take_note"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_o",
										"value": "surround_parens",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + O"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.surround_parens"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_s",
										"value": "search_web",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + S"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.search_web"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_sc029",
										"value": "screen_capture_instant",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + ²"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.screen_capture_instant"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_t",
										"value": "teleport_mouse",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + T"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.teleport_mouse"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_u",
										"value": "uppercase_selection",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + U"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.uppercase_selection"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_w",
										"value": "titlecase_selection",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + W"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.titlecase_selection"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_x",
										"value": "pick_color",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + X"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.pick_color"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.win_space",
										"value": "llm_generate_prediction",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Win + "
											},
											{
												"key": "common.key_space"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.llm_generate_prediction"
											}
										]
									},
									{
										"path": "shortcuts.tap_keys.number_row_left",
										"value": "screenshot_fullscreen_save",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.shortcuts.tap_keys.number_row_left"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.screenshot_fullscreen_save"
											}
										]
									}
								]
							}
						],
						"master": {
							"path": "category_enabled.shortcuts",
							"default": false
						},
						"sub_switch": {
							"path": "category_enabled.key_combinations",
							"default": true,
							"items": [
								"shortcuts.key_combination_taps.alt_gr_then_left_alt",
								"shortcuts.key_combination_taps.alt_gr_then_caps_lock",
								"shortcuts.key_combination_taps.left_alt_then_caps_lock"
							]
						}
					},
					{
						"id": "gestures",
						"title_key": "menu.gestures.title",
						"question_key": "menu.gestures.enable",
						"description_key": "onboarding.gestures.desc",
						"consent": false,
						"groups": [
							{
								"items": [
									{
										"path": "gestures.swipe_3_down",
										"value": "tab_close",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_3_down"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.tab_close"
											}
										]
									},
									{
										"path": "gestures.swipe_3_left",
										"value": "tab_prev",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_3_left"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.tab_prev"
											}
										]
									},
									{
										"path": "gestures.swipe_3_right",
										"value": "tab_next",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_3_right"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.tab_next"
											}
										]
									},
									{
										"path": "gestures.swipe_3_up",
										"value": "tab_new",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_3_up"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.tab_new"
											}
										]
									},
									{
										"path": "gestures.swipe_4_down",
										"value": "win_app_prev",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_4_down"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.win_app_prev"
											}
										]
									},
									{
										"path": "gestures.swipe_4_left",
										"value": "desktop_prev",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_4_left"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.desktop_prev"
											}
										]
									},
									{
										"path": "gestures.swipe_4_right",
										"value": "desktop_next",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_4_right"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.desktop_next"
											}
										]
									},
									{
										"path": "gestures.swipe_4_up",
										"value": "win_app_next",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_4_up"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.win_app_next"
											}
										]
									},
									{
										"path": "gestures.tap_3",
										"value": "left_click_toggle",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.tap_3"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.left_click_toggle"
											}
										]
									},
									{
										"path": "gestures.tap_4",
										"value": "alt_tab_monitor",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.tap_4"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.alt_tab_monitor"
											}
										]
									}
								]
							}
						],
						"master": {
							"path": "gestures.enabled",
							"default": false
						}
					},
					{
						"id": "keyboard_layout",
						"title_key": "menu.layout.title",
						"question_key": "menu.layout.enable",
						"description_key": "onboarding.page.keyboard_layout.description",
						"consent": false,
						"groups": [
							{
								"items": [
									{
										"path": "layout.ergopti_base",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "layout.ergoptibase"
											}
										]
									},
									{
										"path": "layout.direct_access_digits",
										"value": "digits",
										"default": "native",
										"recommended": true,
										"label": [
											{
												"key": "menu.layout.number_row"
											}
										]
									},
									{
										"path": "layout.ergopti_alt_gr",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "layout.ergoptialtgr"
											}
										]
									},
									{
										"path": "layout.ergopti_plus",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "layout.ergoptiplus"
											}
										]
									}
								]
							}
						],
						"master": {
							"path": "category_enabled.layout",
							"default": false
						}
					},
					{
						"id": "hotstrings",
						"title_key": "menu.hotstrings.title",
						"question_key": "menu.hotstrings.enable",
						"description_key": "onboarding.page.hotstrings.description",
						"consent": false,
						"groups": [
							{
								"select_all": true,
								"groups": [
									{
										"path": "category_enabled.autocorrection",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "hotstrings/autocorrection.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.autocorrection.caps.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/autocorrection.toml#caps"
													}
												]
											}
										]
									},
									{
										"path": "category_enabled.magic_key",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "hotstrings/magickey.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.magic_key.replace.enabled",
												"value": true,
												"default": false,
												"recommended": true,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/magickeyreplace.toml#replace"
													}
												]
											},
											{
												"path": "hotstrings.magic_key.repeat_corrections.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/repeatcorrections.toml#repeat_corrections"
													}
												]
											},
											{
												"path": "hotstrings.magic_key.text_expansion_symbols.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/magickey.toml#text_expansion_symbols"
													}
												]
											},
											{
												"path": "hotstrings.magic_key.text_expansion_symbols_typst.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/magickey.toml#text_expansion_symbols_typst"
													}
												]
											}
										]
									},
									{
										"path": "category_enabled.distances_reduction",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.distances_reduction.qu.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#qu"
													}
												]
											},
											{
												"path": "hotstrings.distances_reduction.comma_j.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#comma_j"
													}
												]
											},
											{
												"path": "hotstrings.distances_reduction.comma_far_letters.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#comma_far_letters"
													}
												]
											},
											{
												"path": "hotstrings.distances_reduction.dead_key_e_circumflex.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#dead_key_e_circumflex"
													}
												]
											},
											{
												"path": "hotstrings.distances_reduction.e_circumflex_e.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#e_circumflex_e"
													}
												]
											},
											{
												"path": "hotstrings.distances_reduction.space_around_symbols.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#space_around_symbols"
													}
												]
											}
										]
									},
									{
										"path": "category_enabled.sfbs_reduction",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.sfbs_reduction.comma.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#comma"
													}
												]
											},
											{
												"path": "hotstrings.sfbs_reduction.e_circ.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#e_circ"
													}
												]
											},
											{
												"path": "hotstrings.sfbs_reduction.e_grave.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#e_grave"
													}
												]
											},
											{
												"path": "hotstrings.sfbs_reduction.bu.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#bu"
													}
												]
											},
											{
												"path": "hotstrings.sfbs_reduction.i_e_acute.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#i_e_acute"
													}
												]
											}
										]
									},
									{
										"path": "category_enabled.rolls",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "layouts/registry/ergopti/hotstrings/rolls.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.rolls.hc.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "HC ➜ WH"
													}
												]
											},
											{
												"path": "hotstrings.rolls.sx.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "SX ➜ SK"
													}
												]
											},
											{
												"path": "hotstrings.rolls.cx.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "CX ➜ CK"
													}
												]
											},
											{
												"path": "hotstrings.rolls.english_negation.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "NT’ ➜ N’T"
													}
												]
											},
											{
												"path": "hotstrings.rolls.ez.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "EÉ ➜ EZ"
													}
												]
											},
											{
												"path": "hotstrings.rolls.ct.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "P’ ➜ CT"
													}
												]
											},
											{
												"path": "hotstrings.rolls.close_chevron_tag.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "<@ ➜ </"
													}
												]
											},
											{
												"path": "hotstrings.rolls.chevron_less.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "<% ➜ <="
													}
												]
											},
											{
												"path": "hotstrings.rolls.chevron_greater.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": ">% ➜ >="
													}
												]
											},
											{
												"path": "hotstrings.rolls.comment_open.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "\\\" ➜ /*"
													}
												]
											},
											{
												"path": "hotstrings.rolls.comment_close.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "\"\\ ➜ */"
													}
												]
											},
											{
												"path": "hotstrings.rolls.assign.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "#! ➜ :="
													}
												]
											},
											{
												"path": "hotstrings.rolls.not_equal.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "!# ➜ !="
													}
												]
											},
											{
												"path": "hotstrings.rolls.paren_quote.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "(# ➜ (\""
													}
												]
											},
											{
												"path": "hotstrings.rolls.bracket_quote.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "[# ➜ [\""
													}
												]
											},
											{
												"path": "hotstrings.rolls.hashtag_parenthesis.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "#( ➜ \")"
													}
												]
											},
											{
												"path": "hotstrings.rolls.hashtag_open_bracket.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "#[ ➜ \"]"
													}
												]
											},
											{
												"path": "hotstrings.rolls.hashtag_close_bracket.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "#] ➜ \"]"
													}
												]
											},
											{
												"path": "hotstrings.rolls.equal_string.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "[) ➜ = \"\""
													}
												]
											},
											{
												"path": "hotstrings.rolls.left_arrow.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "=+ = ➜"
													}
												]
											},
											{
												"path": "hotstrings.rolls.assign_arrow_equal_right.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "$= ➜ =>"
													}
												]
											},
											{
												"path": "hotstrings.rolls.assign_arrow_equal_left.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "=$ ➜ <="
													}
												]
											},
											{
												"path": "hotstrings.rolls.assign_arrow_minus_right.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "+? ➜ ->"
													}
												]
											},
											{
												"path": "hotstrings.rolls.assign_arrow_minus_left.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "?+ ➜ <-"
													}
												]
											}
										]
									}
								],
								"label": [
									{
										"key": "onboarding.hotstrings.all_languages"
									}
								]
							},
							{
								"select_all": true,
								"groups": [
									{
										"path": "category_enabled.french_autocorrection",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "hotstrings/french/autocorrection.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.french_autocorrection.accents.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#accents"
													}
												]
											},
											{
												"path": "hotstrings.french_autocorrection.names.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#names"
													}
												]
											},
											{
												"path": "hotstrings.french_autocorrection.typographic_apostrophe.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#typographic_apostrophe"
													}
												]
											},
											{
												"path": "hotstrings.french_autocorrection.errors.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#errors"
													}
												]
											},
											{
												"path": "hotstrings.french_autocorrection.ou.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#ou"
													}
												]
											},
											{
												"path": "hotstrings.french_autocorrection.multiple_punctuation_marks.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#multiple_punctuation_marks"
													}
												]
											},
											{
												"path": "hotstrings.french_autocorrection.suffixes_a_chaining.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#suffixes_a_chaining"
													}
												]
											},
											{
												"path": "hotstrings.french_autocorrection.minus.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#minus"
													}
												]
											},
											{
												"path": "hotstrings.french_autocorrection.minus_apostrophe.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#minus_apostrophe"
													}
												]
											}
										]
									},
									{
										"path": "category_enabled.french_magickey",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "hotstrings/french/magickey.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.french_magickey.text_expansion.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/magickey.toml#text_expansion"
													}
												]
											},
											{
												"path": "hotstrings.french_magickey.text_expansion_auto.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/magickey.toml#text_expansion_auto"
													}
												]
											},
											{
												"path": "hotstrings.french_magickey.text_expansion_emojis.enabled",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/magickey.toml#text_expansion_emojis"
													}
												]
											}
										]
									}
								],
								"label": [
									{
										"text": "🇫🇷 Français"
									}
								]
							}
						],
						"master": {
							"path": "category_enabled.hotstrings",
							"default": false
						},
						"magic_key": {
							"path": "hotstrings.trigger_char",
							"default": "★",
							"recommended": "★",
							"label_key": "onboarding.magic_key.desc",
							"hint_key": "onboarding.magic_key.choose_freely",
							"custom_label_key": "onboarding.magic_key.option_custom",
							"max_characters": 1,
							"options": [
								{
									"value": "★",
									"label_key": "onboarding.magic_key.option_blackstar"
								},
								{
									"value": "ù",
									"label_key": "onboarding.magic_key.option_ugrave"
								},
								{
									"value": ";",
									"label_key": "onboarding.magic_key.option_semicolon"
								}
							]
						}
					},
					{
						"id": "llm",
						"title_key": "menu.llm.title",
						"question_key": "menu.llm.enable",
						"description_key": "onboarding.page.llm.description",
						"consent": false,
						"groups": [],
						"master": {
							"path": "llm.enabled",
							"default": false
						}
					},
					{
						"id": "metrics",
						"title_key": "menu.metrics.title",
						"question_key": "menu.metrics.enable",
						"description_key": "onboarding.metrics.desc",
						"consent": true,
						"groups": [],
						"master": {
							"path": "metrics.metrics_enabled",
							"default": false
						}
					}
				]
			},
			"macos": {
				"manifest_platform": "hs",
				"pages": [
					{
						"id": "tap_holds",
						"title_key": "menu.tapholds.title",
						"question_key": "menu.tapholds.enable",
						"description_key": "onboarding.page.tap_holds.description",
						"consent": false,
						"groups": [
							{
								"label": [
									{
										"key": "menu.tapholds.left_hand_tap_hold"
									}
								],
								"items": [
									{
										"path": "tap_holds.keys.tab",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "tab",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.tab"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.alt_tab_windows"
														}
													],
													[
														{
															"text": "Fn"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.caps_lock",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "caps_lock",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.caps_lock"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.enter"
														}
													],
													[
														{
															"text": "Cmd"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.left_shift",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "left_shift",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.left_shift"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.copy"
														}
													],
													[
														{
															"text": "Shift"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.fn",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "fn",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.fn"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.paste"
														}
													],
													[
														{
															"text": "Cmd"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.left_control",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "left_control",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.left_ctrl"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.cut"
														}
													],
													[
														{
															"text": "Ctrl"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.left_option",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "left_option",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.left_option"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.delete"
														}
													],
													[
														{
															"text": "Cmd+Shift"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.left_command",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "left_command",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.left_command"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.backspace"
														}
													],
													[
														{
															"text": "Layer (hold)"
														}
													]
												]
											}
										]
									}
								]
							},
							{
								"label": [
									{
										"key": "menu.tapholds.right_hand_tap_hold"
									}
								],
								"items": [
									{
										"path": "tap_holds.keys.right_command",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "right_command",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.right_command"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.tab"
														}
													],
													[
														{
															"text": "AltGr"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.right_option",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "right_option",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.right_option"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.sticky_shift"
														}
													],
													[
														{
															"text": "Shift"
														}
													]
												]
											}
										]
									}
								]
							}
						],
						"state": {
							"path": "tap_holds.enabled",
							"default": false
						}
					},
					{
						"id": "shortcuts",
						"title_key": "menu.shortcuts.title",
						"question_key": "menu.shortcuts.enable",
						"description_key": "onboarding.page.shortcuts.description",
						"consent": false,
						"groups": [
							{
								"items": [
									{
										"path": "shortcuts.keyboard.hs_ctrl_space",
										"value": "llm_generate_prediction",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + "
											},
											{
												"key": "common.key_space"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.llm_generate_prediction"
											}
										]
									},
									{
										"path": "shortcuts.tap_keys.number_row_left",
										"value": "screenshot_fullscreen_save",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.shortcuts.tap_keys.number_row_left"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.screenshot_fullscreen_save"
											}
										]
									},
									{
										"path": "shortcuts.keys.wrap_text_if_selected",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "menu.shortcuts.selection_symbol"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_wrap_text"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_a",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + A"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_a"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_d",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + D"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_d"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_e",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + E"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_e"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_g",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + G"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_g"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_h",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + H"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_h"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_i",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + I"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_i"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_m",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + M"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_m"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_o",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + O"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_o"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_p",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + P"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_p"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_s",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + S"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_s"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_t",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + T"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_t"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_u",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + U"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_u"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_w",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + W"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_w"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_x",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + X"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_x"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_capslock",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + CapsLock"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_capslock"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_l",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + L"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_l"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_period",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + ."
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_period"
											}
										]
									},
									{
										"path": "shortcuts.keys.ctrl_quote",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + '"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_ctrl_quote"
											}
										]
									},
									{
										"path": "shortcuts.keys.cmd_shift_v",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Cmd + Shift + V"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_cmd_shift_v"
											}
										]
									},
									{
										"path": "shortcuts.keys.cmd_star",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"text": "Cmd + ★"
											}
										],
										"value_label": [
											{
												"key": "shortcuts.label_cmd_star"
											}
										]
									}
								]
							}
						],
						"master": {
							"path": "shortcuts.enabled",
							"default": false
						}
					},
					{
						"id": "gestures",
						"title_key": "menu.gestures.title",
						"question_key": "menu.gestures.enable",
						"description_key": "onboarding.gestures.desc",
						"consent": false,
						"groups": [
							{
								"items": [
									{
										"path": "gestures.swipe_3_down",
										"value": "tab_next",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_3_down"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.tab_next"
											}
										]
									},
									{
										"path": "gestures.swipe_3_left",
										"value": "sel_word_prev",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_3_left"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.sel_word_prev"
											}
										]
									},
									{
										"path": "gestures.swipe_3_right",
										"value": "sel_word_next",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_3_right"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.sel_word_next"
											}
										]
									},
									{
										"path": "gestures.swipe_3_up",
										"value": "tab_prev",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_3_up"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.tab_prev"
											}
										]
									},
									{
										"path": "gestures.tap_3",
										"value": "left_click_toggle",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.tap_3"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.left_click_toggle"
											}
										]
									},
									{
										"path": "gestures.tap_4",
										"value": "win_app_next",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.tap_4"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.win_app_next"
											}
										]
									},
									{
										"path": "gestures.swipe_2_left",
										"value": "arrow_up",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_2_left"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.arrow_up"
											}
										]
									},
									{
										"path": "gestures.swipe_3_horiz",
										"value": "words",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_3_horiz"
											}
										],
										"value_label": [
											{
												"key": "ax_actions.words"
											}
										]
									},
									{
										"path": "gestures.swipe_4_horiz",
										"value": "spaces",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_4_horiz"
											}
										],
										"value_label": [
											{
												"key": "ax_actions.spaces"
											}
										]
									},
									{
										"path": "gestures.swipe_5_horiz",
										"value": "windows",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.gestures.swipe_5_horiz"
											}
										],
										"value_label": [
											{
												"key": "ax_actions.windows"
											}
										]
									}
								]
							}
						],
						"master": {
							"path": "gestures.enabled",
							"default": false
						},
						"hint_key": "dialog.gestures.warning_msg"
					},
					{
						"id": "keyboard_layout",
						"title_key": "menu.layout.title",
						"question_key": "menu.layout.enable",
						"description_key": "onboarding.page.keyboard_layout.description",
						"consent": false,
						"groups": [],
						"note_key": "onboarding.page.keyboard_layout.system_note"
					},
					{
						"id": "hotstrings",
						"title_key": "menu.hotstrings.title",
						"question_key": "menu.hotstrings.enable",
						"description_key": "onboarding.page.hotstrings.description",
						"consent": false,
						"groups": [
							{
								"select_all": true,
								"groups": [
									{
										"path": "hotstrings.groups.autocorrection",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "hotstrings/autocorrection.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.autocorrection.caps",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/autocorrection.toml#caps"
													}
												]
											}
										]
									},
									{
										"path": "hotstrings.groups.magickey",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "hotstrings/magickey.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.magickey.replace",
												"value": true,
												"default": false,
												"recommended": true,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/magickeyreplace.toml#replace"
													}
												]
											},
											{
												"path": "hotstrings.modules.magickey.repeat_corrections",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/repeatcorrections.toml#repeat_corrections"
													}
												]
											},
											{
												"path": "hotstrings.modules.magickey.text_expansion_symbols",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/magickey.toml#text_expansion_symbols"
													}
												]
											},
											{
												"path": "hotstrings.modules.magickey.text_expansion_symbols_typst",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/magickey.toml#text_expansion_symbols_typst"
													}
												]
											}
										]
									},
									{
										"path": "hotstrings.groups.distancesreduction",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.distancesreduction.qu",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#qu"
													}
												]
											},
											{
												"path": "hotstrings.modules.distancesreduction.comma_j",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#comma_j"
													}
												]
											},
											{
												"path": "hotstrings.modules.distancesreduction.comma_far_letters",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#comma_far_letters"
													}
												]
											},
											{
												"path": "hotstrings.modules.distancesreduction.dead_key_e_circumflex",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#dead_key_e_circumflex"
													}
												]
											},
											{
												"path": "hotstrings.modules.distancesreduction.e_circumflex_e",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#e_circumflex_e"
													}
												]
											},
											{
												"path": "hotstrings.modules.distancesreduction.space_around_symbols",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#space_around_symbols"
													}
												]
											}
										]
									},
									{
										"path": "hotstrings.groups.sfbsreduction",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.sfbsreduction.comma",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#comma"
													}
												]
											},
											{
												"path": "hotstrings.modules.sfbsreduction.e_circ",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#e_circ"
													}
												]
											},
											{
												"path": "hotstrings.modules.sfbsreduction.e_grave",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#e_grave"
													}
												]
											},
											{
												"path": "hotstrings.modules.sfbsreduction.bu",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#bu"
													}
												]
											},
											{
												"path": "hotstrings.modules.sfbsreduction.i_e_acute",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#i_e_acute"
													}
												]
											}
										]
									},
									{
										"path": "hotstrings.groups.rolls",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "layouts/registry/ergopti/hotstrings/rolls.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.rolls.hc",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "HC ➜ WH"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.sx",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "SX ➜ SK"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.cx",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "CX ➜ CK"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.english_negation",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "NT’ ➜ N’T"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.ez",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "EÉ ➜ EZ"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.ct",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "P’ ➜ CT"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.close_chevron_tag",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "<@ ➜ </"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.chevron_less",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "<% ➜ <="
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.chevron_greater",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": ">% ➜ >="
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.comment_open",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "\\\" ➜ /*"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.comment_close",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "\"\\ ➜ */"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.assign",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "#! ➜ :="
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.not_equal",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "!# ➜ !="
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.paren_quote",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "(# ➜ (\""
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.bracket_quote",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "[# ➜ [\""
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.hashtag_parenthesis",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "#( ➜ \")"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.hashtag_open_bracket",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "#[ ➜ \"]"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.hashtag_close_bracket",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "#] ➜ \"]"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.equal_string",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "[) ➜ = \"\""
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.left_arrow",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "=+ = ➜"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.assign_arrow_equal_right",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "$= ➜ =>"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.assign_arrow_equal_left",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "=$ ➜ <="
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.assign_arrow_minus_right",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "+? ➜ ->"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.assign_arrow_minus_left",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "?+ ➜ <-"
													}
												]
											}
										]
									}
								],
								"label": [
									{
										"key": "onboarding.hotstrings.all_languages"
									}
								]
							},
							{
								"select_all": true,
								"groups": [
									{
										"path": "hotstrings.groups.french_autocorrection",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "hotstrings/french/autocorrection.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.french_autocorrection.accents",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#accents"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.names",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#names"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.typographic_apostrophe",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#typographic_apostrophe"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.errors",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#errors"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.ou",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#ou"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.multiple_punctuation_marks",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#multiple_punctuation_marks"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.suffixes_a_chaining",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#suffixes_a_chaining"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.minus",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#minus"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.minus_apostrophe",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#minus_apostrophe"
													}
												]
											}
										]
									},
									{
										"path": "hotstrings.groups.french_magickey",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "hotstrings/french/magickey.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.french_magickey.text_expansion",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/magickey.toml#text_expansion"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_magickey.text_expansion_auto",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/magickey.toml#text_expansion_auto"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_magickey.text_expansion_emojis",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/magickey.toml#text_expansion_emojis"
													}
												]
											}
										]
									}
								],
								"label": [
									{
										"text": "🇫🇷 Français"
									}
								]
							},
							{
								"label": [
									{
										"key": "menu.hotstrings.preview_bubbles"
									}
								],
								"select_all": true,
								"items": [
									{
										"path": "hotstrings.preview_star_enabled",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "menu.hotstrings.tooltip_magic"
											}
										]
									},
									{
										"path": "hotstrings.preview_autocorrect_enabled",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "menu.hotstrings.tooltip_autocorrect"
											}
										]
									},
									{
										"path": "hotstrings.preview_colored_tooltips",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "menu.hotstrings.tooltip_colored"
											}
										]
									}
								]
							}
						],
						"master": {
							"path": "hotstrings.enabled",
							"default": false
						},
						"magic_key": {
							"path": "hotstrings.trigger_char",
							"default": "★",
							"recommended": "★",
							"label_key": "onboarding.magic_key.desc",
							"hint_key": "onboarding.magic_key.choose_freely",
							"custom_label_key": "onboarding.magic_key.option_custom",
							"max_characters": 1,
							"options": [
								{
									"value": "★",
									"label_key": "onboarding.magic_key.option_blackstar"
								},
								{
									"value": "ù",
									"label_key": "onboarding.magic_key.option_ugrave"
								},
								{
									"value": ";",
									"label_key": "onboarding.magic_key.option_semicolon"
								}
							]
						}
					},
					{
						"id": "llm",
						"title_key": "menu.llm.title",
						"question_key": "menu.llm.enable",
						"description_key": "onboarding.page.llm.description",
						"consent": false,
						"groups": [],
						"master": {
							"path": "llm.enabled",
							"default": false
						}
					},
					{
						"id": "metrics",
						"title_key": "menu.metrics.title",
						"question_key": "menu.metrics.enable",
						"description_key": "onboarding.metrics.desc",
						"consent": true,
						"groups": [],
						"master": {
							"path": "metrics.enabled",
							"default": false
						}
					}
				]
			},
			"linux": {
				"manifest_platform": "linux",
				"pages": [
					{
						"id": "tap_holds",
						"title_key": "menu.tapholds.title",
						"question_key": "menu.tapholds.enable",
						"description_key": "onboarding.page.tap_holds.description",
						"consent": false,
						"groups": [
							{
								"label": [
									{
										"key": "menu.tapholds.left_hand_tap_hold"
									}
								],
								"items": [
									{
										"path": "tap_holds.keys.tab",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "tab",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.tab"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.alt_tab_monitor"
														}
													],
													[
														{
															"key": "tap_hold.hold.alt"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.caps_lock",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "caps_lock",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.caps_lock"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.enter"
														}
													],
													[
														{
															"key": "tap_hold.hold.ctrl"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.left_shift",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "left_shift",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.left_shift"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.copy"
														}
													],
													[
														{
															"key": "tap_hold.hold.shift"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.left_ctrl",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "left_ctrl",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.left_ctrl"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.paste"
														}
													],
													[
														{
															"key": "tap_hold.hold.ctrl"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.left_alt",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "left_alt",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.left_alt"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.backspace"
														}
													],
													[
														{
															"key": "tap_hold.hold.nav_layer"
														}
													]
												]
											}
										]
									}
								]
							},
							{
								"label": [
									{
										"key": "menu.tapholds.right_hand_tap_hold"
									}
								],
								"items": [
									{
										"path": "tap_holds.keys.alt_gr",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "alt_gr",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.alt_gr"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.tab"
														}
													],
													[
														{
															"key": "tap_hold.hold.alt_gr"
														}
													]
												]
											}
										]
									},
									{
										"path": "tap_holds.keys.right_ctrl",
										"value": true,
										"default": false,
										"recommended": true,
										"tap_hold_key": "right_ctrl",
										"customised_value": "customised",
										"label": [
											{
												"key": "tap_hold.group.right_ctrl"
											}
										],
										"value_label": [
											{
												"template": "onboarding.checklist.tap_hold",
												"args": [
													[
														{
															"key": "sg_actions.one_shot_shift"
														}
													],
													[
														{
															"key": "tap_hold.hold.shift"
														}
													]
												]
											}
										]
									}
								]
							}
						],
						"state": {
							"path": "tap_holds.enabled",
							"default": false
						}
					},
					{
						"id": "shortcuts",
						"title_key": "menu.shortcuts.title",
						"question_key": "menu.shortcuts.enable",
						"description_key": "onboarding.page.shortcuts.description",
						"consent": false,
						"groups": [
							{
								"items": [
									{
										"path": "shortcuts.wrap_text_if_selected",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "shortcuts.label_wrap_text"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.ctrl_g",
										"value": "open_chatgpt",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Ctrl + G"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.open_chatgpt"
											}
										]
									},
									{
										"path": "shortcuts.keyboard.super_space",
										"value": "llm_generate_prediction",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"text": "Super + "
											},
											{
												"key": "common.key_space"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.llm_generate_prediction"
											}
										]
									},
									{
										"path": "shortcuts.tap_keys.number_row_left",
										"value": "screenshot_fullscreen_save",
										"default": "none",
										"recommended": true,
										"label": [
											{
												"key": "menu.shortcuts.tap_keys.number_row_left"
											}
										],
										"value_label": [
											{
												"key": "sg_actions.screenshot_fullscreen_save"
											}
										]
									}
								]
							}
						],
						"master": {
							"path": "shortcuts.enabled",
							"default": false
						}
					},
					{
						"id": "gestures",
						"title_key": "menu.gestures.title",
						"question_key": "menu.gestures.enable",
						"description_key": "onboarding.gestures.desc",
						"consent": false,
						"groups": [],
						"master": {
							"path": "gestures.enabled",
							"default": false
						},
						"hint_key": "gestures.system.warning"
					},
					{
						"id": "keyboard_layout",
						"title_key": "menu.layout.title",
						"question_key": "menu.layout.enable",
						"description_key": "onboarding.page.keyboard_layout.description",
						"consent": false,
						"groups": [],
						"note_key": "onboarding.page.keyboard_layout.system_note"
					},
					{
						"id": "hotstrings",
						"title_key": "menu.hotstrings.title",
						"question_key": "menu.hotstrings.enable",
						"description_key": "onboarding.page.hotstrings.description",
						"consent": false,
						"groups": [
							{
								"select_all": true,
								"groups": [
									{
										"path": "hotstrings.groups.autocorrection",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "hotstrings/autocorrection.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.autocorrection.caps",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/autocorrection.toml#caps"
													}
												]
											}
										]
									},
									{
										"path": "hotstrings.groups.magickey",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "hotstrings/magickey.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.magickey.replace",
												"value": true,
												"default": false,
												"recommended": true,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/magickeyreplace.toml#replace"
													}
												]
											},
											{
												"path": "hotstrings.modules.magickey.repeat_corrections",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/repeatcorrections.toml#repeat_corrections"
													}
												]
											},
											{
												"path": "hotstrings.modules.magickey.text_expansion_symbols",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/magickey.toml#text_expansion_symbols"
													}
												]
											},
											{
												"path": "hotstrings.modules.magickey.text_expansion_symbols_typst",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/magickey.toml#text_expansion_symbols_typst"
													}
												]
											}
										]
									},
									{
										"path": "hotstrings.groups.distancesreduction",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.distancesreduction.qu",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#qu"
													}
												]
											},
											{
												"path": "hotstrings.modules.distancesreduction.comma_j",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#comma_j"
													}
												]
											},
											{
												"path": "hotstrings.modules.distancesreduction.comma_far_letters",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#comma_far_letters"
													}
												]
											},
											{
												"path": "hotstrings.modules.distancesreduction.dead_key_e_circumflex",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#dead_key_e_circumflex"
													}
												]
											},
											{
												"path": "hotstrings.modules.distancesreduction.e_circumflex_e",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#e_circumflex_e"
													}
												]
											},
											{
												"path": "hotstrings.modules.distancesreduction.space_around_symbols",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/distancesreduction.toml#space_around_symbols"
													}
												]
											}
										]
									},
									{
										"path": "hotstrings.groups.sfbsreduction",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.sfbsreduction.comma",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#comma"
													}
												]
											},
											{
												"path": "hotstrings.modules.sfbsreduction.e_circ",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#e_circ"
													}
												]
											},
											{
												"path": "hotstrings.modules.sfbsreduction.e_grave",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#e_grave"
													}
												]
											},
											{
												"path": "hotstrings.modules.sfbsreduction.bu",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#bu"
													}
												]
											},
											{
												"path": "hotstrings.modules.sfbsreduction.i_e_acute",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "layouts/registry/ergopti/hotstrings/sfbsreduction.toml#i_e_acute"
													}
												]
											}
										]
									},
									{
										"path": "hotstrings.groups.rolls",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "layouts/registry/ergopti/hotstrings/rolls.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.rolls.hc",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "HC ➜ WH"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.sx",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "SX ➜ SK"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.cx",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "CX ➜ CK"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.english_negation",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "NT’ ➜ N’T"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.ez",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "EÉ ➜ EZ"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.ct",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "P’ ➜ CT"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.close_chevron_tag",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "<@ ➜ </"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.chevron_less",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "<% ➜ <="
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.chevron_greater",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": ">% ➜ >="
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.comment_open",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "\\\" ➜ /*"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.comment_close",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "\"\\ ➜ */"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.assign",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "#! ➜ :="
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.not_equal",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "!# ➜ !="
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.paren_quote",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "(# ➜ (\""
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.bracket_quote",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "[# ➜ [\""
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.hashtag_parenthesis",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "#( ➜ \")"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.hashtag_open_bracket",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "#[ ➜ \"]"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.hashtag_close_bracket",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "#] ➜ \"]"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.equal_string",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "[) ➜ = \"\""
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.left_arrow",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "=+ = ➜"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.assign_arrow_equal_right",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "$= ➜ =>"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.assign_arrow_equal_left",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "=$ ➜ <="
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.assign_arrow_minus_right",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "+? ➜ ->"
													}
												]
											},
											{
												"path": "hotstrings.modules.rolls.assign_arrow_minus_left",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text": "?+ ➜ <-"
													}
												]
											}
										]
									}
								],
								"label": [
									{
										"key": "onboarding.hotstrings.all_languages"
									}
								]
							},
							{
								"select_all": true,
								"groups": [
									{
										"path": "hotstrings.groups.french_autocorrection",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "hotstrings/french/autocorrection.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.french_autocorrection.accents",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#accents"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.names",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#names"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.typographic_apostrophe",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#typographic_apostrophe"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.errors",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#errors"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.ou",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#ou"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.multiple_punctuation_marks",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#multiple_punctuation_marks"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.suffixes_a_chaining",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#suffixes_a_chaining"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.minus",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#minus"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_autocorrection.minus_apostrophe",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/autocorrection.toml#minus_apostrophe"
													}
												]
											}
										]
									},
									{
										"path": "hotstrings.groups.french_magickey",
										"value": true,
										"default": false,
										"label": [
											{
												"text_ref": "hotstrings/french/magickey.toml"
											}
										],
										"items": [
											{
												"path": "hotstrings.modules.french_magickey.text_expansion",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/magickey.toml#text_expansion"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_magickey.text_expansion_auto",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/magickey.toml#text_expansion_auto"
													}
												]
											},
											{
												"path": "hotstrings.modules.french_magickey.text_expansion_emojis",
												"value": true,
												"default": false,
												"recommended": false,
												"label": [
													{
														"text_ref": "hotstrings/french/magickey.toml#text_expansion_emojis"
													}
												]
											}
										]
									}
								],
								"label": [
									{
										"text": "🇫🇷 Français"
									}
								]
							},
							{
								"label": [
									{
										"key": "menu.hotstrings.preview_bubbles"
									}
								],
								"select_all": true,
								"items": [
									{
										"path": "hotstrings.preview_star_enabled",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "menu.hotstrings.tooltip_magic"
											}
										]
									},
									{
										"path": "hotstrings.preview_autocorrect_enabled",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "menu.hotstrings.tooltip_autocorrect"
											}
										]
									},
									{
										"path": "hotstrings.preview_colored_tooltips",
										"value": true,
										"default": false,
										"recommended": true,
										"label": [
											{
												"key": "menu.hotstrings.tooltip_colored"
											}
										]
									}
								]
							}
						],
						"magic_key": {
							"path": "hotstrings.trigger_char",
							"default": "★",
							"recommended": "★",
							"label_key": "onboarding.magic_key.desc",
							"hint_key": "onboarding.magic_key.choose_freely",
							"custom_label_key": "onboarding.magic_key.option_custom",
							"max_characters": 1,
							"validation": "safe_magic_key",
							"options": [
								{
									"value": "★",
									"label_key": "onboarding.magic_key.option_blackstar"
								}
							]
						}
					},
					{
						"id": "llm",
						"title_key": "menu.llm.title",
						"question_key": "menu.llm.enable",
						"description_key": "onboarding.page.llm.description",
						"consent": false,
						"groups": [],
						"master": {
							"path": "llm.enabled",
							"default": false
						}
					},
					{
						"id": "metrics",
						"title_key": "menu.metrics.title",
						"question_key": "menu.metrics.enable",
						"description_key": "onboarding.metrics.desc",
						"consent": true,
						"groups": [],
						"master": {
							"path": "metrics.enabled",
							"default": false
						}
					}
				]
			}
		}
	};
})(window);
