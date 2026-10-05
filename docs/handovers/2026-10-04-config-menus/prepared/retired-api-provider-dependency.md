# Retired API-provider dependency

This bounded archive is a preparation, not an implemented or qualified feature.
Its SHA256 is `4c3d51c2bbf23e04ae8c88681d06cbb9ac18a2cbccc3728baf98657bdb6d5171`.
All nine entries preserve their exact original bytes. The historical source
checkpoint is `f49a0b145`; all six declared native preimages still match
`594f810aa`, and the two causal diagnostic failures were reproduced there.
Credentials in the probe are invented fixture strings; no network call occurs.

The actual Linux store admits a retired provider, makes it active, and adds
owned defaults to its old row during a successful usable-neighbor selection.
The reader and complete-model preservation assertions both fail on current
sources. Before fixing the store, coordinate the minimal published cloud and
local catalogue receipts with the group4 owner. An empty/unavailable catalogue
must never be interpreted as proof of retirement. Reuse the existing raw-row,
selection and warning owners; retain obsolete data until explicit cleanup.
macOS already neutralizes retired transport requests and retains their settings
and credentials. Do not reimplement that behavior or migrate credentials.

Extract the archive into a disposable directory, then run its frozen probe with
the repository's actual LuaJIT environment:

```sh
luajit /path/to/extracted/ergopti-todo33-retired-api-provider-probe.lua /path/to/ergopti reader
luajit /path/to/extracted/ergopti-todo33-retired-api-provider-probe.lua /path/to/ergopti preservation
```

Both commands intentionally exit1 at their independently handwritten unmet
assertions. They are diagnostics, not a registered green suite. The original
note's Linux navigation boot clause was already corrected in TODO33; it is
historical context, not an instruction to redo that completed behavior.
Native ports, full regression integration, packaging, installation and physical
acceptance remain unqualified. The ZIP includes frozen source hashes, the probe,
historical logs and current-source receipts; native source copies are recoverable
from the recorded Git checkpoint.
