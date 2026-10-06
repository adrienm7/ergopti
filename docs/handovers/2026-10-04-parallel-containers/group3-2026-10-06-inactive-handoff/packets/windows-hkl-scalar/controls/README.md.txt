# Native-HKL observation scalar-capture successor

This private successor depends on the immutable observation packet
`23813ae615451aa25d8d2d0ddfc2a9e13aae4e8781590205b664d564d772248b`.
It changes only the validation/publication block of `KS_NativeKeyLevel` and
appends one registered case after the five previously frozen cases.

The optional observation port may return an object with own Count/Text getters.
The predecessor rereads them during validation, classification and publication;
a getter can therefore supply valid intermediate scalars and publish a different,
unchecked count or text. The new helper captures each external scalar exactly
once, then validates/classifies/publishes the captured local values. Getter
throws remain closed zero refusals without diagnostics or exception text.

The new actual AHK case defines stateful own getters: Count supplies one during
all old checks but 999 on the old final read; Text supplies a validated character
during old checks and different unchecked text on the old final read. It asserts
the published Count/Text/Kind and exactly one getter invocation each. It also
tests throwing Count and Text getters. The entire previous five-case source
prefix remains byte-exact. The frozen ten-key corpus and all previous native/KLE
implementations remain unchanged.

Private source controls pass and refuse the predecessor plus two unchecked
publication mutations. The unchanged partial AHK syntax gate, BOM/LF checks,
Ruff and private apply-check pass. These are source controls only. All six new
registered AHK cases, including actual getter behavior, remain UNEXECUTED on
this Linux container. Parent Windows CI must execute the registered native
runner. This is not a forced-native mode or native input/output qualification.

`successor.patch` applies only after the predecessor. `joint.patch` applies the
same final two files against the original actual Root preimages. No Root,
schema, locale, hook, generated source or CI mutation was made.
