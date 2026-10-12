; static/ergopti_plus/_shared/ahk/tap_hold/buffered_data_snapshot_owner.ahk
#Requires AutoHotkey v2.0

; Pure source images, not configuration/input admission. Normal boot owns this
; class and its original builtin ports. Intrinsic object/Func invocation stays
; under normal boot custody, not arbitrary VM-tamper protection. No data getter
; or caller callable runs during capture/match.
; Images retain original container identities as well as detached data facts.
class BufferedDataSnapshotOwner {
	__New() {
		this._class := BufferedDataSnapshotOwner
		this._prototype := BufferedDataSnapshotOwner.Prototype
		this._type := Type
		this._base := ObjGetBase
		this._names := ObjOwnProps
		this._compare := StrCompare
		this._desc := Object.Prototype.GetOwnPropDesc
		this._hasOwn := Object.Prototype.HasOwnProp
		this._mapClass := Map
		this._arrayClass := Array
		this._objectClass := Object
		this._boolClass := TOML_Bool
		this._funcClass := Func
		this._funcBase := Func.Prototype
		this._mapBase := Map.Prototype
		this._arrayBase := Array.Prototype
		this._objectBase := Object.Prototype
		this._boolBase := TOML_Bool.Prototype
		this._mapEnum := Map.Prototype.__Enum
		this._mapGet := Map.Prototype.Get
		this._mapHas := Map.Prototype.Has
		this._mapDelete := Map.Prototype.Delete
		this._mapClear := Map.Prototype.Clear
		this._mapItemGet := this._desc.Call(Map.Prototype, "__Item").Get
		this._mapItemSet := this._desc.Call(Map.Prototype, "__Item").Set
		this._mapCount := this._desc.Call(Map.Prototype, "Count").Get
		this._mapCase := this._desc.Call(Map.Prototype, "CaseSense").Get
		this._arrayLength := this._desc.Call(Array.Prototype, "Length").Get
		this._arrayHas := Array.Prototype.Has
		this._arrayEnum := Array.Prototype.__Enum
		this._arrayPush := Array.Prototype.Push
		this._arrayGet := this._desc.Call(Array.Prototype, "__Item").Get
		this._methods := Map()
		for Name in ["__New", "Current", "Capture", "Matches", "Release", "Clear", "_Read", "_Equal", "_Scalar", "_Descriptor"]
			this._methods[Name] := this._desc.Call(this._prototype, Name).Call
		this._descriptorPort := this._mapGet.Call(this._methods, "_Descriptor").Bind(this)
		this._images := Map()
		this._objectMeta := Map()
		for Name in ["__Get", "__Set", "__Call", "__Enum"]
			this._objectMeta[Name] := this._hasOwn.Call(this._objectBase, Name)
				? this._desc.Call(this._objectBase, Name) : 0
	}

	_Descriptor(Source, Name, Field, Expected) {
		try {
			Description := this._desc.Call(Source, Name)
			return this._hasOwn.Call(Description, Field) && Description.%Field% = Expected
		} catch Any {
			return false
		}
	}

	Current() {
		if BufferedDataSnapshotOwner != this._class || Type != this._type
			|| ObjGetBase != this._base || ObjOwnProps != this._names || StrCompare != this._compare
			|| Map != this._mapClass || Array != this._arrayClass || Object != this._objectClass
			|| TOML_Bool != this._boolClass || Func != this._funcClass
			return false
		for _, Method in this._mapEnum.Call(this._methods, 2)
			if this._hasOwn.Call(Method, "Call")
				return false
		if !this._descriptorPort.Call(this._class, "Prototype", "Value", this._prototype)
			|| !this._descriptorPort.Call(this._mapClass, "Prototype", "Value", this._mapBase)
			|| !this._descriptorPort.Call(this._arrayClass, "Prototype", "Value", this._arrayBase)
			|| !this._descriptorPort.Call(this._objectClass, "Prototype", "Value", this._objectBase)
			|| !this._descriptorPort.Call(this._boolClass, "Prototype", "Value", this._boolBase)
			|| !this._descriptorPort.Call(this._funcClass, "Prototype", "Value", this._funcBase)
			|| !this._descriptorPort.Call(this._objectBase, "GetOwnPropDesc", "Call", this._desc)
			|| !this._descriptorPort.Call(this._objectBase, "HasOwnProp", "Call", this._hasOwn)
			|| !this._descriptorPort.Call(this._mapBase, "__Enum", "Call", this._mapEnum)
			|| !this._descriptorPort.Call(this._mapBase, "Get", "Call", this._mapGet)
			|| !this._descriptorPort.Call(this._mapBase, "Has", "Call", this._mapHas)
			|| !this._descriptorPort.Call(this._mapBase, "Delete", "Call", this._mapDelete)
			|| !this._descriptorPort.Call(this._mapBase, "Clear", "Call", this._mapClear)
			|| !this._descriptorPort.Call(this._mapBase, "__Item", "Get", this._mapItemGet)
			|| !this._descriptorPort.Call(this._mapBase, "__Item", "Set", this._mapItemSet)
			|| !this._descriptorPort.Call(this._mapBase, "Count", "Get", this._mapCount)
			|| !this._descriptorPort.Call(this._mapBase, "CaseSense", "Get", this._mapCase)
			|| !this._descriptorPort.Call(this._arrayBase, "Length", "Get", this._arrayLength)
			|| !this._descriptorPort.Call(this._arrayBase, "Has", "Call", this._arrayHas)
			|| !this._descriptorPort.Call(this._arrayBase, "__Enum", "Call", this._arrayEnum)
			|| !this._descriptorPort.Call(this._arrayBase, "Push", "Call", this._arrayPush)
			|| !this._descriptorPort.Call(this._arrayBase, "__Item", "Get", this._arrayGet)
			return false
		for Name, Method in this._mapEnum.Call(this._methods, 2)
			if this._hasOwn.Call(this, Name) || !this._descriptorPort.Call(this._prototype, Name, "Call", Method)
				return false
		for Name, Image in this._mapEnum.Call(this._objectMeta, 2) {
			Exists := this._hasOwn.Call(this._objectBase, Name)
			if (this._type.Call(Image) = "Integer") {
				if Exists
					return false
				continue
			}
			if !Exists
				return false
			Actual := this._desc.Call(this._objectBase, Name)
			for _, Field in this._arrayEnum.Call(["Value", "Get", "Set", "Call"], 2) {
				Present := this._hasOwn.Call(Image, Field)
				if Present != this._hasOwn.Call(Actual, Field)
					|| (Present && Image.%Field% != Actual.%Field%)
					return false
			}
		}
		return true
	}

	Capture(Value) {
		CurrentOwner := this._mapGet.Call(this._methods, "Current")
		if this._hasOwn.Call(CurrentOwner, "Call") || !CurrentOwner.Call(this)
			throw Error("Original data snapshot ports changed")
		Image := this._mapGet.Call(this._methods, "_Read").Call(this, Value, Map())
		Token := {}
		this._images[Token] := Image
		return Token
	}

	Matches(Value, Token) {
		try {
			CurrentOwner := this._mapGet.Call(this._methods, "Current")
			if this._hasOwn.Call(CurrentOwner, "Call") || !CurrentOwner.Call(this) || !this._mapHas.Call(this._images, Token)
				return false
			Actual := this._mapGet.Call(this._methods, "_Read").Call(this, Value, Map())
			return this._mapGet.Call(this._methods, "_Equal").Call(this, Actual, this._images[Token])
		} catch Any {
			return false
		}
	}

	; Snapshot cleanup is not native lifecycle closure. Captured original
	; builtin cleanup remains available after class/export revocation.
	Release(Token) {
		if this._mapHas.Call(this._images, Token)
			this._mapDelete.Call(this._images, Token)
		return true
	}

	Clear() {
		this._mapClear.Call(this._images)
		return true
	}

	_Read(Value, Active) {
		Kind := this._type.Call(Value)
		if Kind = "String" || Kind = "Integer" || Kind = "Float"
			return { Kind: Kind, Value: Value }
		; Callables are retained identities, never sampled/invoked or deep-cloned.
		if Kind = "Func" || Kind = "BoundFunc" || Kind = "Closure" {
			if this._hasOwn.Call(Value, "Call")
				throw TypeError("Original callable has a substituted Call descriptor")
			FunctionBase := this._base.Call(Value)
			while FunctionBase != this._funcBase {
				if FunctionBase = this._objectBase
					throw TypeError("Function leaf has no original Func base")
				FunctionBase := this._base.Call(FunctionBase)
			}
			return { Kind: Kind, Value: Value }
		}
		Base := this._base.Call(Value)
		if !((Kind = "Map" && Base = this._mapBase)
			|| (Kind = "Array" && Base = this._arrayBase)
			|| (Kind = "Object" && Base = this._objectBase)
			|| (Kind = "TOML_Bool" && Base = this._boolBase))
			throw TypeError("Unsupported original data snapshot leaf")
		if Active.Has(Value)
			throw ValueError("Cyclic original data snapshot")
		Active[Value] := true
		try {
			Image := { Kind: Kind, Reference: Value, Base: Base, Entries: [] }
			if Kind = "Map" || Kind = "Array" {
				for _, Name in this._arrayEnum.Call(["__Enum", "__Item", "Get", "Has", "Count",
					"CaseSense", "Length", "Push", "Delete", "Clear"], 2)
					if this._hasOwn.Call(Value, Name)
						throw TypeError("Container operation has an own descriptor")
				; Name-only intrinsic enumeration does not evaluate user getters.
				for Name in this._names.Call(Value)
					throw TypeError("Named container properties are not original data")
				if Kind = "Map" {
					Image.Mode := this._mapCase.Call(Value)
					Image.Length := this._mapCount.Call(Value)
					for Key, Item in this._mapEnum.Call(Value, 2) {
						KeyKind := this._type.Call(Key)
						if KeyKind != "String" && KeyKind != "Integer"
							throw TypeError("Unsupported original data snapshot key")
						this._arrayPush.Call(Image.Entries, { Key: Key, KeyKind: KeyKind,
							Value: this._mapGet.Call(this._methods, "_Read").Call(this, Item, Active) })
					}
				} else {
					Image.Length := this._arrayLength.Call(Value)
					loop Image.Length {
						Present := this._arrayHas.Call(Value, A_Index)
						Entry := { Key: A_Index, Present: Present }
						if Present
							Entry.Value := this._mapGet.Call(this._methods, "_Read").Call(this,
								this._arrayGet.Call(Value, A_Index), Active)
						this._arrayPush.Call(Image.Entries, Entry)
					}
				}
			} else {
				; Generated action Objects carry mutable Fn/Key/Mods fields. Retain
				; every own data descriptor; an accessor refuses without execution.
				for Name in this._names.Call(Value) {
					Description := this._desc.Call(Value, Name)
					if !this._hasOwn.Call(Description, "Value")
						throw TypeError("Accessors are not original snapshot data")
					this._arrayPush.Call(Image.Entries, { Key: Name, KeyKind: "String",
						Value: this._mapGet.Call(this._methods, "_Read").Call(this, Description.Value, Active) })
				}
				Image.Length := Image.Entries.Length
				if Kind = "TOML_Bool" && (Image.Length != 1 || Image.Entries[1].Key != "Value"
					|| Image.Entries[1].Value.Kind != "Integer"
					|| (Image.Entries[1].Value.Value != 0 && Image.Entries[1].Value.Value != 1))
					throw TypeError("Malformed original typed Boolean")
			}
			return Image
		} finally {
			Active.Delete(Value)
		}
	}

	_Scalar(Left, Right) {
		return Left.Kind = Right.Kind && (Left.Kind = "String"
			? this._compare.Call(Left.Value, Right.Value, true) = 0 : Left.Value = Right.Value)
	}

	_Equal(Left, Right) {
		if Left.Kind != Right.Kind
			return false
		if Left.HasOwnProp("Value")
			return this._mapGet.Call(this._methods, "_Scalar").Call(this, Left, Right)
		if Left.Reference != Right.Reference || Left.Base != Right.Base || Left.Length != Right.Length
			|| (Left.Kind = "Map" && Left.Mode != Right.Mode)
			return false
		for Index, Entry in this._arrayEnum.Call(Left.Entries, 2) {
			Other := Right.Entries[Index]
			if Left.Kind = "Array" {
				if Entry.Present != Other.Present
					return false
				if !Entry.Present
					continue
			} else if Entry.KeyKind != Other.KeyKind || (Entry.KeyKind = "String"
				? this._compare.Call(Entry.Key, Other.Key, true) != 0 : Entry.Key != Other.Key)
				return false
			if !this._mapGet.Call(this._methods, "_Equal").Call(this, Entry.Value, Other.Value)
				return false
		}
		return true
	}
}
