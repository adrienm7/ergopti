; _shared/modules/hotstrings/user_code.ahk

; ==============================================================================
; MODULE: Programmable Dynamic Hotstring Ownership (Windows Port)
; DESCRIPTION:
; Ports the shared descriptor and revocable execution contract. Native source,
; process, destination and input owners retain publication authority.
; ==============================================================================

/** Recognizes the exact native Boolean publication receipt. */
UserCodeAcknowledged(Value) {
	return (Value is Integer) && Value == 1
}

/** Validates UTF-16 scalar values before their native UTF-8 transport. */
UserCodeTextValid(Value, Metadata := false) {
	if !(Value is String) || Value == ""
		return false
	if Metadata && (InStr(Value, "`n") || InStr(Value, "`r"))
		return false
	Index := 1
	while Index <= StrLen(Value) {
		Scalar := Ord(SubStr(Value, Index, 1))
		if Scalar >= 0xD800 && Scalar <= 0xDBFF {
			if Index == StrLen(Value)
				return false
			Next := Ord(SubStr(Value, Index + 1, 1))
			if Next < 0xDC00 || Next > 0xDFFF
				return false
			Index += 1
		} else if Scalar >= 0xDC00 && Scalar <= 0xDFFF
			return false
		Index += 1
	}
	return true
}

/** Validates and detaches ordered metadata without executing callbacks. */
UserCodeValidate(Rules, &Reason) {
	Reason := ""
	if !(Rules is Array) {
		Reason := "invalid-rules"
		return false
	}
	Owned := [], Ids := Map(), Suffixes := Map()
	Suffixes.CaseSense := "On"
	loop Rules.Length {
		if !Rules.Has(A_Index) {
			Reason := "invalid-rule-order"
			return false
		}
		Rule := Rules[A_Index]
		if !(Rule is Map) || !Rule.Has("id") || !Rule.Has("suffix") || !Rule.Has("preview")
			|| !Rule.Has("callback") || !UserCodeTextValid(Rule["id"], true)
			|| !(Rule["id"] ~= "^[a-z][a-z0-9_]*$") || !UserCodeTextValid(Rule["suffix"], true)
			|| !UserCodeTextValid(Rule["preview"], true) || !HasMethod(Rule["callback"], "Call") {
			Reason := "invalid-rule"
			return false
		}
		for Key in Rule {
			if Key !== "id" && Key !== "suffix" && Key !== "preview" && Key !== "callback" {
				Reason := "unknown-rule-field"
				return false
			}
		}
		if Ids.Has(Rule["id"]) || Suffixes.Has(Rule["suffix"]) {
			Reason := "duplicate-rule"
			return false
		}
		Ids[Rule["id"]] := true
		Suffixes[Rule["suffix"]] := true
		Owned.Push(Map("id", Rule["id"], "suffix", Rule["suffix"], "preview", Rule["preview"], "callback", Rule["callback"]))
	}
	return Owned
}

/** Encodes exact UTF-8 text for the isolated worker's line-framed transport. */
UserCodeEncode(Value) {
	if !(Value is String)
		throw TypeError("User-code transport requires text.")
	Bytes := StrPut(Value, "UTF-8") - 1
	BufferValue := Buffer(Bytes + 1, 0)
	StrPut(Value, BufferValue, "UTF-8")
	Encoded := ""
	loop Bytes
		Encoded .= Format("{:02x}", NumGet(BufferValue, A_Index - 1, "UChar"))
	return Encoded
}

/** Decodes only canonical UTF-8 hexadecimal transport, refusing lossy input. */
UserCodeDecode(Value) {
	if !(Value is String) || Mod(StrLen(Value), 2) || !(Value ~= "^[0-9a-f]*$")
		throw ValueError("Invalid user-code transport.")
	Bytes := StrLen(Value) // 2
	BufferValue := Buffer(Bytes + 1, 0)
	loop Bytes
		NumPut("UChar", Integer("0x" . SubStr(Value, 2 * A_Index - 1, 2)), BufferValue, A_Index - 1)
	Decoded := StrGet(BufferValue, Bytes, "UTF-8")
	if !(UserCodeEncode(Decoded) == Value)
		throw ValueError("Invalid user-code UTF-8 transport.")
	return Decoded
}

/** Owns the same metadata and lazy revocable native operations as the Lua port. */
class UserHotstringOwner {
	__New(Ports) {
		if !(Ports is Map)
			throw TypeError("Programmable hotstrings require native ports.")
		for Name in ["capture", "current", "invoke", "commit", "report"] {
			if !Ports.Has(Name) || !HasMethod(Ports[Name], "Call")
				throw TypeError("A programmable hotstring native port is missing.")
		}
		this.ports := Ports
		this.entries := []
		this.source := 0
		this.generation := 0
		this.enabled := false
		this.stopped := false
		this.ready := false
		this.active := Map()
		this.debt := []
	}

	Report(Kind, Id) {
		return UserCodeAcknowledged(this.ports["report"].Call(Kind, Id))
	}

	Cancel(Operation) {
		try return HasMethod(Operation, "cancel") && UserCodeAcknowledged(Operation.cancel())
		catch as Err {
			this.Report("cancellation-failed", "operation")
			return false
		}
	}

	Invalidate(Reason) {
		this.generation += 1
		Retiring := this.active
		this.active := Map()
		for Ticket in Retiring {
			if Ticket.Has("operation") && !this.Cancel(Ticket["operation"])
				this.debt.Push(Ticket["operation"])
		}
		Retained := []
		for Operation in this.debt {
			if !this.Cancel(Operation)
				Retained.Push(Operation)
		}
		this.debt := Retained
		if Retained.Length
			this.Report("cancellation-refused", Reason)
		return !Retained.Length
	}

	Reload(Rules, Source) {
		this.ready := false
		Cancelled := this.Invalidate("reload")
		Staged := UserCodeValidate(Rules, &Reason)
		if !(Source is Map) || !Source.Has("path") || !UserCodeTextValid(Source["path"], true)
			|| !Source.Has("present") || !(Source["present"] is Integer)
			|| (Source["present"] != 0 && Source["present"] != 1)
			|| !Source.Has("content") || !(Source["content"] is String)
			|| (!Source["present"] && Source["content"] != "")
			Reason := "invalid-source"
		else if !Source["present"]
			Reason := "source-missing"
		if Reason != "" || !Cancelled {
			this.enabled := false
			this.Report(Reason != "" ? Reason : "cancellation-refused", "load")
			return false
		}
		this.entries := Staged
		this.source := Map("path", Source["path"], "present", Source["present"], "content", Source["content"])
		this.ready := true
		return true
	}

	; Quarantine retained metadata after source admission fails. Closing never
	; discards an unacknowledged native cancellation or fabricates a loaded source.
	RefuseSource(Reason) {
		this.enabled := false
		this.ready := false
		return this.Invalidate(Reason)
	}

	SetEnabled(Value) {
		if !(Value is Integer) || (Value != 0 && Value != 1) || this.stopped
			return false
		this.enabled := false
		if !this.Invalidate("enabled")
			return false
		this.enabled := Value
		return true
	}

	Stop() {
		this.enabled := false
		this.stopped := true
		this.ready := false
		return this.Invalidate("stop")
	}

	Find(BufferValue) {
		if !this.enabled || this.stopped || !this.ready || this.debt.Length || !(BufferValue is String)
			return false
		for Rule in this.entries {
			if SubStr(BufferValue, -StrLen(Rule["suffix"])) == Rule["suffix"]
				return Rule
		}
		return false
	}

	Preview(BufferValue) {
		Rule := this.Find(BufferValue)
		return Rule is Map ? Map("id", Rule["id"], "suffix", Rule["suffix"], "preview", Rule["preview"]) : false
	}

	Retained(Ticket) {
		return this.active.Has(Ticket) && Ticket["generation"] == this.generation
			&& this.enabled && !this.stopped && this.ready
	}

	Current(Ticket) {
		if !this.Retained(Ticket)
			return false
		try return UserCodeAcknowledged(this.ports["current"].Call(Ticket["capture"], Ticket["source"])) && this.Retained(Ticket)
		catch
			return false
	}

	Request(BufferValue) {
		Rule := this.Find(BufferValue)
		if !(Rule is Map)
			return false
		Epoch := this.generation
		try Capture := this.ports["capture"].Call(Rule)
		catch {
			this.Report("capture-refused", Rule["id"])
			return false
		}
		if !(Capture is Object) || Epoch != this.generation
			return false
		Ticket := Map("generation", Epoch, "capture", Capture, "rule", Rule, "source", this.source.Clone())
		this.active[Ticket] := Ticket
		Context := Map("id", Rule["id"], "suffix", Rule["suffix"], "cancelled", () => !this.Current(Ticket))
		Done(Result, Failure := "") {
			if !this.Current(Ticket) {
				if this.active.Has(Ticket)
					this.active.Delete(Ticket)
				return false
			}
			Valid := (Result is String) ? UserCodeTextValid(Result) : ((Result is Integer) && (Result == 0 || Result == 1))
			if Failure != "" || !Valid {
				this.Report(Failure != "" ? "execution-failed" : "invalid-result", Rule["id"])
				Result := false
			}
			if !this.Current(Ticket)
				return false
			try Ack := UserCodeAcknowledged(this.ports["commit"].Call(Result, Capture, Rule))
			finally {
				if this.active.Has(Ticket)
					this.active.Delete(Ticket)
			}
			if !Ack
				this.Report("output-refused", Rule["id"])
			return Ack
		}
		try Operation := this.ports["invoke"].Call(Rule, Context, Done, Capture)
		catch {
			this.active.Delete(Ticket)
			this.Report("launch-refused", Rule["id"])
			return false
		}
		if !HasMethod(Operation, "start") || !HasMethod(Operation, "cancel") {
			this.active.Delete(Ticket)
			this.Report("launch-refused", Rule["id"])
			return false
		}
		Ticket["operation"] := Operation
		try Started := this.Retained(Ticket) && UserCodeAcknowledged(Operation.start())
		catch
			Started := false
		if !Started {
			if this.active.Has(Ticket)
				this.active.Delete(Ticket)
			if !this.Cancel(Operation)
				this.debt.Push(Operation)
			return false
		}
		return true
	}

	Rules() {
		Records := []
		for Rule in this.entries
			Records.Push(Map("id", Rule["id"], "suffix", Rule["suffix"], "preview", Rule["preview"]))
		return Records
	}

	Count() {
		return this.entries.Length
	}
}
