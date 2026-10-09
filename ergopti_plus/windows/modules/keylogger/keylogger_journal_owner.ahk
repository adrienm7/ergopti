; modules/keylogger/keylogger_journal_owner.ahk

; ==============================================================================
; MODULE: Keylogger Journal Ownership
; DESCRIPTION:
; Serializes journal operations and retains an exact file owner until refused
; compensation is repaired. No filesystem work runs while Critical is held.
; ==============================================================================

class KL_JournalOwner {
	__New() {
		if this.HasOwnProp("_Token")
			throw Error("Journal ownership cannot be initialized twice.")
		this._Token := 0
		this._Debt := 0
		this._Repairing := false
		this.Failure := ""
	}

	Acquire() {
		PreviousCritical := Critical("On")
		try {
			if IsObject(this._Token)
				return 0
			Token := {}
			this._Token := Token
		} finally {
			Critical(PreviousCritical)
		}
		try {
			if this.HasDebt() && !this._AttemptRepair() {
				this.Release(Token)
				return 0
			}
			return Token
		} catch {
			this.Release(Token)
			throw
		}
	}

	Require(Token) {
		if !IsObject(Token) || Token != this._Token
			throw Error("Journal operation requires its current ownership token.")
	}

	Release(Token) {
		PreviousCritical := Critical("On")
		try {
			this.Require(Token)
			if this._Repairing
				throw Error("Journal compensation cannot relinquish its active owner.")
			this._Token := 0
		} finally {
			Critical(PreviousCritical)
		}
	}

	HasDebt() {
		return IsObject(this._Debt)
	}

	Rollback(Token, FileObject, Boundary, RollbackFn) {
		this.Require(Token)
		if this.HasDebt()
			throw Error("Journal compensation cannot replace unresolved debt.")
		if !IsObject(FileObject) || Type(Boundary) != "Integer" || Boundary < 0
			throw ValueError("Journal compensation requires a file and a byte boundary.")
		if !HasMethod(RollbackFn, "Call")
			throw TypeError("Journal compensation requires a callable repair operation.")
		this._Debt := {File: FileObject, Boundary: Boundary, Repair: RollbackFn}
		return this._AttemptRepair()
	}

	_AttemptRepair() {
		this.Require(this._Token)
		if this._Repairing
			throw Error("Journal compensation cannot reenter its repair operation.")
		this._Repairing := true
		PreviousCritical := Critical("Off")
		try {
			Debt := this._Debt
			Receipt := Debt.Repair.Call(Debt.File, Debt.Boundary)
			if Type(Receipt) != "Integer" || Receipt != 1 {
				this.Failure := Type(Receipt) = "Integer" && Receipt = 0 ? "refused" : "invalid_receipt"
				return false
			}
			this._Debt := 0
			this.Failure := ""
			return true
		} catch Any as Err {
			; The owner, not the callback or a path lookup, retains recovery authority.
			this.Failure := Type(Err)
			return false
		} finally {
			Critical(PreviousCritical)
			this._Repairing := false
		}
	}
}
