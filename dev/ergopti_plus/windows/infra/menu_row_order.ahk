; infra/menu_row_order.ahk

; ==============================================================================
; MODULE: Menu Row Order
; DESCRIPTION:
; The Windows reader of the display-order rules of the menus, the same answers as
; _shared/lua/menu/row_order.lua from the generated projection of
; _shared/modules/menu/row_order.json. No Windows file spells an order of its own
; (tools/test/test-menu-row-order-single-source.cjs).
;
; FEATURES & RATIONALE:
; 1. An unknown rule throws: a typo must not silently sort nothing.
; 2. Callers get detached copies, so one menu cannot reorder another's rule.
; 3. A name outside a rule ranks after every listed name and compares by text,
;    so a new entry shows up last instead of vanishing.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../_generated/menu_row_order.ahk

_MenuRowOrderRule(Name) {
	if !(Name is String) || !MENU_ROW_ORDER_DATA.Has(Name)
		throw ValueError("unknown menu row order rule: " . String(Name))
	return MENU_ROW_ORDER_DATA[Name]
}

; The ordered names of one rule.
; @param Name {String} Rule name from row_order.json.
; @returns {Array} A fresh array.
MenuRowOrderList(Name) {
	return _MenuRowOrderRule(Name).Clone()
}

; The position of every name of one rule.
; @param Name {String} Rule name from row_order.json.
; @returns {Map} Case-sensitive name -> 1-based position.
MenuRowOrderRank(Name) {
	Rank := Map()
	for Index, Item in _MenuRowOrderRule(Name)
		Rank[Item] := Index
	return Rank
}

; A copy of Items in the order of one rule; unlisted names follow the listed ones
; and compare by text among themselves.
; @param Name {String} Rule name from row_order.json.
; @param Items {Array} The names to order.
; @returns {Array} A fresh sorted array.
MenuRowOrderSorted(Name, Items) {
	Rank := MenuRowOrderRank(Name)
	Unlisted := Rank.Count + 1
	Sorted := []
	for Item in Items {
		Position := Sorted.Length + 1
		ItemRank := Rank.Get(Item, Unlisted)
		while Position > 1 {
			Previous := Sorted[Position - 1]
			PreviousRank := Rank.Get(Previous, Unlisted)
			if PreviousRank < ItemRank || (PreviousRank == ItemRank && StrCompare(Previous, Item, true) <= 0)
				break
			Position -= 1
		}
		Sorted.InsertAt(Position, Item)
	}
	return Sorted
}
