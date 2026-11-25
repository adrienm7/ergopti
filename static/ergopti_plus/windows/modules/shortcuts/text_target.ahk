; modules/shortcuts/text_target.ahk

; ==============================================================================
; MODULE: Text Targets (AutoHotkey port)
; DESCRIPTION:
; Port of _shared/shortcuts/engine/text_target.lua: finds a caption such as
; « Autoriser une fois » among the words a text recognition returned, so the
; auto-clicker and the user workflows click a button by its text whatever its
; theme. The macOS and Linux drivers run the shared module.
;
; FEATURES & RATIONALE:
; 1. The same comparison form, character for character: ASCII letters
;    lowered, every other character folded through
;    _shared/core/text/data/text_fold.json or kept, punctuation and spaces read
;    as one space. StrLower is not used: it would lower scripts the shared
;    table leaves alone, and the two drivers would then disagree.
; 2. Characters are code points: a surrogate pair counts as one character in
;    the edit distance, as one UTF-8 sequence does in Lua.
; 3. The same runs (k - 1 to k + 1 words of one line) and the same choice
;    (distance, then word-count gap, then reading order).
;
; Pinned by _shared/tests/corpus/keep_awake/text_target_vectors.json, which
; tests/unit/modules/shortcuts/test_text_target.ahk replays.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================
; ==================================
; ======= 1/ Normalisation =========
; ==================================
; ==================================

; The folding table, read once from the shared data.
TextTargetFold() {
	global _SharedDir
	static Fold := 0
	if !IsObject(Fold)
		Fold := JsonParse(FileRead(_SharedDir . "\core\text\data\text_fold.json", "UTF-8"))["fold"]
	return Fold
}

; The non-ASCII characters read as a separator, as the shared SEPARATORS.
_TextTargetIsSeparator(Code) {
	static Codes := Map(0xA0, 1, 0x202F, 1, 0x2009, 1, 0x2026, 1, 0xAB, 1, 0xBB, 1, 0x2018, 1, 0x2019, 1,
		0x201C, 1, 0x201D, 1, 0x2013, 1, 0x2014, 1, 0x200B, 1, 0x200C, 1, 0x200D, 1, 0xFEFF, 1)
	return Codes.Has(Code)
}

; Splits a string into code points, a surrogate pair kept together.
; @returns {Array} One string per character.
TextTargetCharacters(Text) {
	Out := []
	Index := 1
	Length := StrLen(Text)
	while Index <= Length {
		Code := Ord(SubStr(Text, Index, 2))
		Size := (Code > 0xFFFF) ? 2 : 1
		Out.Push(SubStr(Text, Index, Size))
		Index += Size
	}
	return Out
}

; Normalises a text for comparison: lower case, no accents, single spaces.
TextTargetNormalize(Text) {
	if !(Text is String)
		throw TypeError("A text target is a string.")
	Fold := TextTargetFold()
	Out := ""
	for Char in TextTargetCharacters(Text) {
		Code := Ord(Char)
		if Code < 0x80 {
			if (Code >= 48 && Code <= 57) || (Code >= 97 && Code <= 122)
				Out .= Char
			else if Code >= 65 && Code <= 90
				Out .= Chr(Code + 32)
			else
				Out .= " "
		} else if _TextTargetIsSeparator(Code) {
			Out .= " "
		} else {
			Out .= Fold.Has(Char) ? Fold[Char] : Char
		}
	}
	Out := RegExReplace(Out, " +", " ")
	return Trim(Out, " ")
}

; The edit distance between two normalised texts, in characters.
TextTargetDistance(A, B) {
	Ca := TextTargetCharacters(A), Cb := TextTargetCharacters(B)
	Previous := []
	Loop Cb.Length + 1
		Previous.Push(A_Index - 1)
	I := 1
	while I <= Ca.Length {
		Current := [I]
		J := 1
		while J <= Cb.Length {
			Cost := (Ca[I] == Cb[J]) ? 0 : 1
			Current.Push(Min(Previous[J + 1] + 1, Current[J] + 1, Previous[J] + Cost))
			J += 1
		}
		Previous := Current
		I += 1
	}
	return Previous[Cb.Length + 1]
}




; ==================================
; ==================================
; ======= 2/ Matching ==============
; ==================================
; ==================================

_TextTargetLines(Words) {
	Lines := [], ById := Map()
	for Index, Word in Words {
		Normalised := TextTargetNormalize(Word["text"])
		if Normalised = ""
			continue
		Id := Word["line"]
		if !ById.Has(Id) {
			ById[Id] := []
			Lines.Push(ById[Id])
		}
		ById[Id].Push(Map("word", Word, "text", Normalised, "order", Index))
	}
	return Lines
}

_TextTargetWordCount(Text) {
	return Text = "" ? 0 : StrSplit(Text, " ").Length
}

; Finds the best hit of one target among recognised words.
; @param Words {Array} Maps text, x, y, width, height, line.
; @param Target {Map} id, variants, max_distance.
; @returns {Map|String} id, variant, text, x, y, width, height, distance; "" when none.
TextTargetFind(Words, Target) {
	MaxDistance := Target["max_distance"]
	if !IsInteger(MaxDistance) || MaxDistance < 0
		throw ValueError("A text target's max_distance is a non-negative integer.")
	Best := "", BestGap := 0, BestOrder := 0
	Lines := _TextTargetLines(Words)
	for Variant in Target["variants"] {
		Wanted := TextTargetNormalize(Variant)
		K := _TextTargetWordCount(Wanted)
		if K = 0
			continue
		for Line in Lines {
			Size := Max(1, K - 1)
			while Size <= K + 1 {
				Start := 1
				while Start <= Line.Length - Size + 1 {
					Text := "", X0 := "", Y0 := "", X1 := "", Y1 := ""
					Loop Size {
						Entry := Line[Start + A_Index - 1]
						W := Entry["word"]
						Text .= (A_Index = 1 ? "" : " ") . Entry["text"]
						X0 := X0 = "" ? W["x"] : Min(X0, W["x"])
						Y0 := Y0 = "" ? W["y"] : Min(Y0, W["y"])
						X1 := X1 = "" ? W["x"] + W["width"] : Max(X1, W["x"] + W["width"])
						Y1 := Y1 = "" ? W["y"] + W["height"] : Max(Y1, W["y"] + W["height"])
					}
					Distance := TextTargetDistance(Text, Wanted)
					if Distance <= MaxDistance {
						Gap := Abs(Size - K), Order := Line[Start]["order"]
						if !IsObject(Best) || Distance < Best["distance"]
							|| (Distance = Best["distance"] && (Gap < BestGap || (Gap = BestGap && Order < BestOrder))) {
							Best := Map("id", Target["id"], "variant", Variant, "text", Text, "x", X0, "y", Y0,
								"width", X1 - X0, "height", Y1 - Y0, "distance", Distance)
							BestGap := Gap, BestOrder := Order
						}
					}
					Start += 1
				}
				Size += 1
			}
		}
	}
	return Best
}

; Finds the best hit of each target, in target order.
; @returns {Array} The hits; a target with none is left out.
TextTargetFindAll(Words, Targets) {
	Hits := []
	for Target in Targets {
		Hit := TextTargetFind(Words, Target)
		if IsObject(Hit)
			Hits.Push(Hit)
	}
	return Hits
}
