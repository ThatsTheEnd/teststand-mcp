# TestStandMCP — Behavior Rules for Claude

## User-facing rules (imported from the plugin skill)

The rules a plugin user needs live in the `teststand-rules` skill, which is their single source: edit them there, never here. The imports below load them into every session in this repository. `build/Test-SkillSources.ps1` fails when a moved heading reappears in this file or an import dangles.

@plugin/skills/teststand-rules/SKILL.md
@plugin/skills/teststand-rules/references/rebuild.md
@plugin/skills/teststand-rules/references/sequence-design.md
@plugin/skills/teststand-rules/references/agents.md
@plugin/skills/teststand-rules/references/headless-and-tools.md

## Developer notes behind the imported rules

The skill states each rule for a plugin user: no dates, no test IDs, no class names. The facts below were part of the same sections before they moved; they are the developer-side history, measurements and source pointers. Nothing here is imported into the skill.

**Export/import (whole-file rebuild)**
- Measured 2026-07-29 on 8 sequences of `TFW_MDC_com_Python.seq` (47 steps, 13 object-oriented Python steps, 5 LabVIEW `.lvlibp` steps, 1 cross-file SequenceCall): **3 MCP calls and ZERO FileDiffer differences inside the imported scope** (the only rows left are the 22 sequences not imported). The same rebuild with the granular tools took ~700 calls, 3 diff iterations and left 224 differences.
- A WHOLE-file rebuild reaches `identical: true`, verified 2026-07-29 on `TFW_Symphony_DutCom.seq` (17 sequences, 79 steps, 43 variables, 18 `.lvlibp` panes from TWO packed libraries, 4 cross-file calls, 2 ActiveX steps, 49 types) in 4 MCP calls with 0 warnings.
- An import measured 5.5 min before the passes were made cheap, which is why a `-32001` transport timeout does not abort it and the outcome is also written to `<dest>.import.json`.
- Importing a subset: the in-memory type list still lists a type the save just dropped, so the import detects the loss AFTER a save+reload, re-attaches the types and names them in `warnings`. `attach='preserve'` (what a 1:1 rebuild needs) attaches almost nothing, which is why a type survives only while still referenced.
- The safe defaults (`labview_panes='copy'`, `cross_file_prototypes='copy'`, `variables='copy'`, `keep_unused_types`) are locked down by tests in `T35`. The worker route for the cross-file cache is not a real option: it must start its own engine and open every callee file, and one 3 MB callee (`Easy.Log.seq`) ran it into a 300 s timeout and produced nothing; `'copy'` reproduced the same 6 `Prototype` members in about a second.
- `diff_sequence_files` rows are capped by `DiffReportShaper.DefaultMaxResults` (150), which sits on `Options`, so `compare_sequence_files` in native mode inherits it (`diff_sequence_files` and `compare_sequence_files mode=native` are the same diff).
- Binding connector-pane parameters through `set_module_parameter` measured: 31 differences became 68 (write everything), 41 (non-empty only), 39 (flag-aware) - while writing `ViCall.Parms[i].ArgVal` and `UseDefaultValues` INDEPENDENTLY gave 9. The same asymmetry exists for a SequenceCall argument's `UseDef`.
- The two prototype-load kinds are mutually exclusive per server process (measured 2026-07-29): a LabVIEW pane load first makes the following SeqCall load return `prototypeLoaded:false` ("LoadPrototype could not resolve the target/module"), and the reverse order fails the same way. It no longer constrains a rebuild because both are cloned.
- Residuals closed 2026-07-29, each by cloning from the source file instead of loading: the LabVIEW connector panes (pass 5), the cross-file `Prototype` cache (pass 7), and a step's authored `TS.AdditionalResultsHints` / `CustomResults` / `ErrorDialogOptions` for EVERY step (pass 6b). `copy_typedefs` reproduces every type correctly (0 `types` differences); the declarative route had lost the type INSTANCE, not the type.
- A named-type instance's ENUM member reading as explicitly set was long recorded as an irreducible API limit, which it is NOT. Instantiating the type (`insert_local_variable dataType:"LogEvent"`) materialises the member with its default enumerator NAME written out, so it reads `[Debug]` where the editor-authored original has `{Debug}` (`get_property_tree`: `symbolicName:"Debug", isDefault:false` vs `symbolicName:"", isDefault:true`). Not writing the value does not help: the import already skips it (`isDefault:true` in the model, and `WriteEnumLeafExplicit` returns early on null ordinal+value). `variables='copy'` clones the variable and reproduces the state exactly.
- `NI.Analyzer.IgnoredMessages` is invisible to the engine API, so a rebuild shows a few extra analyzer warnings the original suppresses; FileDiffer's raw reader sees it as a lone `File Properties > Attributes` delete (`identical=false` is expected).
- Typed PropertyObject (2026-07-29): `Clone(path, CopyAllFlags)` then `SetPropertyObject` on a subtree whose node carries a NAMED TYPE re-registers a second instance of the type; the fix writes the leaf scalars (`SetValString`/`SetValNumber`/`SetValBoolean`) on the existing node. Measured: `modulesCloned` dropped 79 -> 47 and the dialog disappeared. The decision lives in `StepCopyPolicy` (scalar compared and written by value, empty list-like node skipped, object copy last resort) and is pinned by tests in `T35`. The FileDiffer reported `identical: true` for the file that raised the dialog. `audit_type_consistency` (2026-07-30) reads the file's `TypeUsageList` RAW, duplicates included, which `EnumerateFileTypeDefs` deliberately hides.
- File format (2026-07-31): `MEDELA_TFW`'s real files are XML, so a rebuild used to come out binary: content-identical yet 25 KB against 3.4 MB on `TFW_MDC_com_Python` (x133, pure serialization). `TestStandService` `ParseFileWritingFormat` / `ApplyFileWritingFormat`; pinned by `T36_FileFormatTests` (13 tests asserting the RAW bytes `TOF1` vs a UTF-8 BOM + `<?xml`). An unknown format name THROWS rather than falling back to binary. The format is the serialization, not the `version` target.
- `.lvlibp` guard (2026-07-30): `InputGuards.IsPackedLibraryModulePath` plus the refusal message; `force_unsafe_inprocess:true` overrides. The in-process load raised the MSVC delay-load SEH `0xC06D007E` (the LabVIEW Run-Time `lvrt.dll`) with LabVIEW 2026 32-bit already started and responsive; it escapes managed `try/catch`, so the server PROCESS DIED and the NI Error Reporter appeared. `isolate:true` is crash-safe but cannot bind the running LabVIEW ADE, so it only times out. After a crash `get_prototype_load_status` reports the job as "unknown or expired".
- Per-sequence clone recipe: see memory `teststand-whole-sequence-clone-rebuild-2026-07-08`.

**Agents**
- The builder's rule is enforced here because `AskUserQuestion` is unavailable to spawned subagents; the orchestrator opens `.claude/agents/teststand-sequence-builder.md` and executes its workflow itself. The doc generator's language question is likewise asked in the main thread before spawning.
- Doc generator: `scripts/generate_teststand_doc.py` (data JSON, dependency diagram via headless Edge/Chrome, `.docx` via python-docx; run with the `py` launcher, plain `python` is not on PATH).
- Presentation generator: `scripts/generate_teststand_presentation.py` plus `scripts/presentation_template.html`; icons via Pillow from `...\National Instruments\TestStand*\Components`; modelled on `.Demo_jcm/TSmcp_demo/index.html` but WITHOUT the QR code / NI-Gold-Partner image. TestStand 2026's Sequence Editor renders its UI with embedded Chromium (CEF), opaque to Windows UI automation (memory `teststand-seqedit-cef-no-automation`); the generator can embed manual PNGs from a folder with `_manifest.json` via `--shots-dir`.

**Headless and tool rules** (the test IDs are the suites that pin each fact)
- Expressions: `T01`, `T08`, `T20`. Properties and variables: `T20`, `T30`, `T33`, `T04`; `configure_labview_module` refuses None-adapter utility steps since 2026-07.
- Headless pause and popups: `T24`, `T25`; `step_results` and process-model entry points: `T27` (memory `teststand-process-model-entry-points`); sync objects: `T19` (`InvalidOperationException` / `NotSupportedException`); `post_ui_message` / `add_report_section` with an unknown id raise `KeyNotFoundException` (`T15`, `T19`); `post_output_message`: `T15`; undo/redo: `T08` (`CanUndo` false on a fresh file).
- The auto-reconnect is `EnsureConnected`: a one-shot lazy reconnect with the default engine path.
- Step-type / enum specifics: `T05`, `T06` (`UseStepUnloadOption` value 5), `T04`, `T10` (`E_JUMP_OUTSIDE_LOOP`); user management `persist:false`: `T11`.
- Live thread context (`T29`): the access path is `Thread.GetSequenceContext(frame).AsPropertyObject()`, the ThisContext tree (`Locals`/`Parameters`/`FileGlobals`/`RunState`/`Step`/`Sequence`). No active frame raises `InvalidOperationException`, a bad `call_stack_index` `ArgumentOutOfRangeException`, an unknown execution `KeyNotFoundException`.
- Validation: `validate_sequence_plan` `T10`, `T31`; `audit_sequence_references` `T28` (pure logic in `ReferenceAuditor`); since 2026-07 the plan validator also checks `Parameters.X` when a `parameters` list is passed.
- Analyzer measured 2026-07-29: ~511 s on the 30-sequence `TFW_MDC_com_Python.seq` once Python 3.11 and LabVIEW were installed and running, versus seconds before when every load failed instantly (a 360 s poll budget looked exactly like a hang). The counting rules are `NI_SequenceFileCount` / `NI_SequenceCount` / `NI_StepCount`. The old 120 s timeout was dead code: `proc.StandardOutput.ReadToEnd()` blocks until the child closes the pipe, so `WaitForExit(120_000)` afterwards always returned true; the pipes now drain via `ReadToEndAsync` and `WaitForExit` enforces `timeout_seconds` (default 900), killing the process tree.
- Analyzer async (2026-07-09): `AnalyzerJob` / `StartAnalyzerJob` / `GetAnalysisStatusAsync` in `TestStandService`, jobs kept in `_analyzerJobs` ~10 min, mirroring the `load_module_prototype` async-job infrastructure. No isolated worker is needed: the fault-prone module loads already happen inside `AnalyzerApp.exe`, which a native `.lvlibp` fault kills without taking the server down. Verified by `T14.AnalyzeDetailed_Async_ReturnsJobThenSameResultAsSync`. New tool name `get_analysis_status` and the `async` param need a FRESH MCP session.
- Flow-step configurability was established by a property-tree audit; `NI_Flow_SweepLoop` / `NI_Flow_StreamLoop` have no configure tool. `validate_sequence_plan` raises `E_CASE_WITHOUT_SELECT` / `E_UNCLOSED_BLOCK` for the Select/Case structure.

---

## Rebuild-efficiency batch (2026-07-29) — behaviour changes to know

Driven by the ~700-call rebuild measured in the developer notes above. See memory `teststand-rebuild-efficiency-batch-2026-07-29`.

- **`copy_typedefs` now PRESERVES the source's attach state** (`attach='preserve'` is the new DEFAULT;
  `'all'` is the old behaviour, `'none'` attaches nothing). It used to attach all 59 types where the
  original embeds 7 — a guaranteed diff and a forced restart of the rebuild.
- **Enum writes always land as EXPLICITLY SET (`[val]`).** `set_property_value` / `set_property_node` /
  `create_step_property` resolve an ordinal to its enumerator NAME first — file type list → engine-wide
  → read back off the property itself — because ONLY the by-name write clears TestStand's type-default
  flag. Previously an ordinal write silently produced `{val}` whenever the enum type was not yet in the
  target file's TypeUsageList (41 spurious diffs in one rebuild).
- **Conversely: do NOT write a value the original leaves at its type default.** `get_property_tree` now
  reports `isDefault` per enum leaf (derived from the symbolic name reading back EMPTY). Writing a
  default-valued member — even a redundant `flags=0` write on a type instance — flips `{val}`→`[val]`.
- **`configure_python_module` is complete.** It now also sets `class_name`,
  `class_instance_location`, `operation_type`/`operation_scope`, `python_version`,
  `virtual_env_path`, `use_adapter_interpreter_settings` and the whole `parameters[]` argument list
  ({name, type, value}) in ONE call. Object-oriented Python steps were previously unreachable
  (~15 `set_step_property` calls each). NOTE: the analyzer's "Python version cannot be empty" ERROR is
  about the STATION's Python Adapter configuration, not this step property — it is present on the
  original file too.
- **`configure_sequence_call_module` writes the retained `SData.SFPath`** (defaults to the current
  file's own name) AFTER the prototype load, which blanks it. `stored_file_path` reproduces a STALE
  path — real files carry paths from before a rename.
- **Numeric REPRESENTATION and format are settable**: `representation` (`float64`/`int64`/`uint64`) and
  `number_format` (e.g. `%#.4x`) on `insert_local_variable`, `insert_sequence_parameter` and
  `set_property_node`; `0x…` literals accepted. This is functional, not cosmetic — a Float64 parameter
  fed a UInt64 argument is a hard `NI_ExpressionEvaluationError`. Wide integers are also READABLE now
  (they used to surface as `Empty` because `GetValNumber` rejects them).
- **`delete_step_property`** removes a step subproperty by dotted path (e.g. one surplus
  `TS.SData.ActualArgs.<name>`). **`set_step_property_flags`/`set_property_node` take `exact`/
  `clear_flags`** to ASSIGN a bitfield instead of OR-ing. (`SetFlags` does in fact replace — the older
  "OR-only" note was wrong.)
- **A `SequenceArgument` keeps its state in SUBPROPERTIES** — `UseDef`, `Expr`, `ParamType`,
  `ParamRepresentation` and its own `Flags` NUMBER (what the FileDiffer shows as the argument's
  "Flags"; NOT the entry's PropFlags). `UseDef` is independent of `Expr`: the editor keeps a remembered
  expression while still using the default. A prototype load overwrites `Flags`/`ParamRepresentation`
  from the callee and renames entries after the callee's CURRENT parameters, so import rebuilds the
  whole list in order rather than patching it (argument ORDER is compared positionally).
- **Bulk writers**: `insert_sequences_bulk`, `insert_variables_bulk`, `set_property_nodes`,
  `set_module_parameters` — one call, one save, applied in array order.
  **Why this dominates:** almost every mutating tool saves the WHOLE file, and the save is ~90 % of the
  cost. Measured on a 21-step/11-KB file: one `Save()` ≈ 26 ms, building all 21 steps without saving
  ≈ 4.7 ms; the same build via single-op tools (~27 saves) ≈ 630 ms vs. bulk (3 saves) ≈ 71 ms — 89 %
  less, and the gap grows with file size. So prefer a bulk writer, and pass `save:false` on the tools
  that offer it (35 of them today) until the last write. Engine start is expensive but amortized — it is
  a cached singleton, only paid again after a server rebuild.
- **`get_property_tree` addresses a sequence/step BY NAME** (`sequence_name` / `step_group` /
  `step_name`); the raw path is `Data.Seq[i].Main[j]` and there is no `Sequences` node.
- **`get_module_parameters` reads Python arguments** (`TS.SData.PythonCall.Parameters`); it returned
  `[]` for every Python step before.
- **Reminder:** new tool NAMES and new enum values/optional params need a FRESH MCP session — the
  client caches the tool catalog at session start.

## Rules moved OUT of this file and INTO the server (2026-07-30)

Six rules that lived here as prose are now guards, defaults or a tool — so they hold for any client and
any fresh session, not only for a reader of this file. Do not re-add the prose versions.

- **A packed-library in-process prototype load is REFUSED**, not warned about
  (`InputGuards.IsPackedLibraryModulePath`, `force_unsafe_inprocess` to override), and
  `configure_labview_module` skips its own auto-load for such a VI with a `note`. The tool descriptions
  no longer recommend `isolate:false` — that advice had survived its retraction and was the one place
  where following the catalog killed the server.
- **`diff_sequence_files` caps its rows at 150 by default** (`DiffReportShaper.DefaultMaxResults`, on
  `Options` so `compare_sequence_files` native mode inherits it); `max_results=0` restores unlimited.
- **`create_sequence_file(overwrite=true)`** performs the close → retry-delete → create dance.
- **`import_sequence_file` removes the destination's leftover `MainSequence`** when the model has none
  (`remove_default_main_sequence`, default true; reported as `defaultMainSequenceRemoved`).
- **`audit_type_consistency`** is new — the only automated check for the type-registration conflicts the
  FileDiffer cannot see.
- Stale tool descriptions fixed: `duplicate_sequence` no longer advertises itself as the whole-file
  rebuild path, `import_sequence_file` reports the measured 0 differences instead of "one, an API limit",
  `diff_sequence_files` no longer calls the LabVIEW panes irreducible, and `copy_step_module` documents
  its minimal-write policy.

New tool NAMES and new params need a **FRESH MCP session** (the client caches the catalog at session
start): `audit_type_consistency`, `force_unsafe_inprocess`, `overwrite`,
`remove_default_main_sequence`, and the changed `max_results` default.

## More rules moved INTO the server (2026-07-31)

Three further memory-only facts are now behaviour or catalog text rather than prose here:

- **The on-disk format is a first-class property.** `file_format` (`binary`|`xml`|`ini`) on
  `create_sequence_file` / `save_sequence_file` / `set_file_properties` / `import_sequence_file`,
  `fileFormat` reported by `get_file_properties` and carried in the export model — so a 1:1 rebuild
  reproduces an XML original as XML instead of silently writing binary. `TestStandService`
  `ParseFileWritingFormat` / `ApplyFileWritingFormat`; pinned by `T36_FileFormatTests` (13 tests,
  asserting the RAW bytes: `TOF1` vs a UTF-8 BOM + `<?xml` — the FileDiffer cannot see this).
  An unknown format name THROWS rather than falling back to binary, which is the whole point.
- **`wait_for_execution` / `get_execution_status` now state the headless `Paused` trap** (a run-time
  error parks on a dialog nobody can answer; raising the timeout never helps) and that `step_results`
  need a process-model entry point.
- **`set_station_global` warns against being polled** from a running sequence — the busy loop starves
  the write and can drop the connection.

Needs a **FRESH MCP session**: the `file_format` params.

## TestStand ENVIRONMENTS (`.tsenv`) — engine internals (2026-08-14, issue #35)

The user-facing half (sources and their precedence, `tsenv_path='auto'` and its search, the restart rule, what the tools report) lives in the imported `headless-and-tools.md`. This is the developer half: how the server makes an environment take effect and how it proves it did.

A station hosting several products isolates each one's `CommonAppData`/`Public`/`LocalAppData` in an **environment** — the Sequence Editor's `/env <path.tsenv>` switch. The server does this in-process via `EngineInitializationSettings.SetEnvironmentPath`, applied on the engine thread immediately before the activation (`ApplyEnvironmentBeforeActivation`), because the call throws once an engine exists.

- **Why it cannot be switched.** One engine per process, `SetEnvironmentPath` throws afterwards, and the last `ShutDown(final:true)` tears down NI licensing. A second `connect_engine` naming a different `.tsenv` is an ERROR telling you to restart the server. Do not try `Engine.LoadEnvironment` — it works by relaunching the application, useless for an in-process headless server.
- **Why the auto-detect looks one level down.** The real layouts put the `.tsenv` in a SIBLING folder (`<root>\Config\X.tsenv` next to `<root>\Components\Sequences\*.seq`), which a parents-only walk never reaches. The config keys are `TestStand:EnvironmentPath` and `TestStand:EnvironmentAutoDetect`; a lazy reconnect reuses the already-active environment.
- **Never trust the setter — the server reads back and so should you.** `CanInitializeEngine()` is asked BEFORE the engine is created (TestStand's own check, which the `Cfg\GeneralEngine.cfg` file probe only approximates), and afterwards `GetEnvironmentPath()` plus `TestStandPath_CommonAppData` vs `TestStandPath_GlobalCommonAppData` prove the redirect took. **Measured on the global environment: `GetEnvironmentPath()` returns EMPTY and the three roots equal their `Global*` counterparts** — so an empty read-back is the honest "no environment", not a failed read. A requested environment that fails both signals makes the connect FAIL rather than silently work against the wrong `CommonAppData`. `get_engine_paths` reports `environmentPath`, `environmentActive`, `environmentDetectedFrom` and the three effective roots; there used to be no way to tell which environment you were in.
- `open_sequence_file` warns on a mismatch (file belongs to environment B, engine runs A/global) — a warning, not an error. It is only computed when the process is environment-aware, so a station without environments sees nothing new.
- **`ConnectAsync` is BOUNDED** (`TestStand:ConnectTimeoutSeconds`, default 120). It used to wait forever; a modal dialog on the engine thread — the classic symptom of an uninitialized `CommonAppData` — hung the tool call and the whole session. On expiry the service latches "restart required" instead of starting a second engine next to the parked one.
- **The CHILD PROCESSES need it too — each starts its OWN engine** (issue #35 follow-up). An environment applied only in-process leaves them on the global station configuration, silently: `AnalyzerApp.exe` (`analyze_sequence_file` / `run_sequence_analyzer`), `FileDiffer.exe` (`diff_sequence_files` / `compare_sequence_files`) and `SeqEdit.exe` (`launch_sequence_editor` / `open_file_in_editor` / `run_in_editor`) all take the same **`/env <path>`** switch — leading flag, space-separated, path quoted (`TestStandEnvironmentLocator.PrependEnvSwitch`). The isolated prototype worker takes **`--tsenv`**. Only the VERIFIED `ActiveEnvironmentPath` is forwarded.
  - **The worker's only channel is that argument.** `Program.cs` dispatches `--load-prototype-worker` BEFORE the `ConfigurationBuilder` runs, so `appsettings.json`, the inherited `TESTSTAND_MCP_` variables and the parent's command line are all invisible to it.
  - **Measured (2026-08-15):** a bogus `/env` hangs `AnalyzerApp.exe` on a modal "Sequence Analyzer" dialog (so the switch IS consumed; a valid one exits 0) — which is harmless here only because the forwarded path was already verified at connect. The environment demonstrably changes the engine's **SearchDirectories** (`C:\Users\Public\Documents\NI\TestStand …` globally vs. the product root under the environment), which is the mechanism by which the analyzer resolves modules differently. Note the analysis of one real file produced IDENTICAL messages either way — the effect is file-dependent, so do not expect every analysis to change.
  - **`SeqEdit.exe` is single-instance:** a running editor keeps the environment it was started with and `/env` cannot retarget it. The server warns rather than implying a match. Which environment a running editor uses cannot be read back — its UI is CEF (see `teststand-seqedit-cef-no-automation`).
- Without a `.tsenv` **not one new COM call happens** — the global path is byte-identical to before.

Needs a **FRESH MCP session**: the `tsenv_path` / `tsenv_search_from` params.

## General Conventions

- **Sequence file for tests:** Always use `DemoTestsequenz.seq`
- **`.Demo_jcm/` is ANONYMIZED demo material — keep it that way.** Those sequences are derived from a
  real customer file and carry a codename instead of the product. When you build, clone or comment
  anything in there: keep the existing codename, and write comments that state the FUNCTIONAL purpose
  only — never the customer, the real product name, the physical measurand or concrete measurement
  values. Sensitive detail lives in the leaf subsequences; if you only scaffold the top sequence, leave
  those as empty stubs. The folder is gitignored on purpose — do NOT record the codename↔product
  mapping in this file or any other tracked file. (The mapping itself is in memory
  `demo-jcm-anonymization-ufo-symphony`.) Comments round-trip through Windows-1252, so ASCII
  punctuation only.
- **MCP server restart:** After code changes always rebuild yourself:
  `taskkill //F //IM TestStandMCP.exe` + `dotnet build --configuration Debug --framework net8.0-windows -p:Platform=x86`
  (Target framework is **net8.0-windows / x86**. The TestStand engine requires the host's
  runtimeconfig to declare `Microsoft.WindowsDesktop.App` + `Microsoft.AspNetCore.App` — both
  are wired via `FrameworkReference` in the .csproj. Output: `bin\x86\Debug\net8.0-windows\`.)
- **After every sequence change:** Call `save_sequence_file`

---

## TestStand Behavioral Facts (proven by the integration tests)

These are hard-won behaviors from the `Test/TestExecution` suite (T01–T21,
`TestBase`, `TestDataBuilder`). Treat them as **known solution paths** — do not
re-discover them by trial-and-error. Per-tool gotchas already live in the tool
descriptions; the cross-cutting rules below apply regardless of which tool you call.

### Calling the TestStand COM API from C# (applies to every tool you add)
- **Any interop method with an `out`/`ref` parameter MUST be called on a TYPED reference.** Via
  `dynamic` or `Type.InvokeMember` the byref params do not marshal: the call throws, a surrounding
  best-effort `catch` swallows it, and the tool returns a plausible DEFAULT instead of an error. Every
  instance of this class of bug was silent and expensive: `Execution.GetStates(out,out)` made **every**
  execution report `Stopped` (so `wait_for_execution` returned instantly), `Thread.GetSequenceContext(0,
  out id)` emptied `get_execution_threads`/`get_thread_status`/`get_thread_call_stack`, and
  `Engine.FindFile` returned the literal `"True"` where a path was expected. A `var x = ...` taken off a
  `dynamic` re-poisons the chain, so cast at the boundary.
- Same rule for the **enum/type APIs**: `TypeUsageList.GetTypeDefinition` throws
  `TargetParameterCountException` under the dynamic binder, and the typed `LabVIEWAdapter` cast is what
  makes `SetServerInfo`/`Initialize` do anything at all (late-bound they no-op silently).
- Related signature traps: `Execution.Restart(bool breakOnEntry)` takes an argument; a `Thread`'s depth
  is **`CallStackSize`** (no `StackDepth`) and it has **no `State`** — read the owning execution's run
  state. (`T23`–`T29`; memories `teststand-getstates-reflection-fails`, `teststand-findfile-modal-prompt`.)
- **A "success" flag from the interop is not evidence — READ THE VALUE BACK.** Two measured cases in
  `configure_dotnet_module` alone (2026-08-03): `SetAssembly` was called as `SetAssembly(path, true)`
  when the signature is `SetAssembly(DotNetModuleAssemblyLocations location, string path)`, so it threw
  into a `catch` that "recovered" by setting a property named `Assembly` — which does not exist — while
  `appliedSettings` reported the path as applied; and **`DotNetModule.LoadMemberInfo` returns `true`
  even for an assembly path that does not exist** (`C:\Dummy\MyAssembly.dll`), so it cannot be used to
  decide whether a member resolved. The real check is `DotNetModule.Calls[0].IsCallValid(out reason)`
  (plus `DotNetModule.AssemblyWarnings` when the reason comes back empty). Report only what a read-back
  confirms; anything else belongs in the result's `note`. Pinned by `T13`.
- **The other four `configure_*_module` tools were AUDITED against their typed interfaces AND the step
  property tree (2026-08-03) — they are correct, do not re-investigate.** Verified landing spots:
  `configure_dll_module` → `CommonCModule.ModulePath`/`.FunctionName` → `TS.SData.Call.LibPath`/`.Func`;
  `configure_labview_module` → `LabVIEWModule.VIPath` → `TS.SData.ViCall.VIPath`;
  `configure_python_module` → `PythonModule.ModulePath`/`.FunctionOrAttributeName` plus the raw
  `TS.SData.PythonCall.*` writes for the object-oriented settings (note the leaf is
  **`ClassInstanceLocation`** while the typed property is `ClassInstanceLocationExpr`);
  `configure_sequence_call_module` → `SeqName`/`UseCurFile`/`SFPath`/`ThreadOpt`/`AsyncThreadExpr`.
  All now go through `TrySetAndVerifyModuleProp` (set + read back), and `T13` asserts the resulting
  TREE, not just `AppliedSettings`. The `|| "ModulePath"` / `|| "FunctionName"` fallbacks they used to
  carry were dead code — those properties do not exist on `LabVIEWModule`/`PythonModule`/`CVIModule`.

### Where a .NET step keeps its configuration (`T13`, 2026-08-03)
- The member to invoke lives in **`TS.SData.Calls[0]`** (`ClassName`, `MemberName`, `MemberType`,
  `Static`, `Params`), NOT in `TS.SData.FunctionName` — that root property stays EMPTY even on a
  correctly configured step, so do not assert on it. The assembly, however, IS at the root:
  **`TS.SData.AssemblyPath`** (+ `AssemblyLocation`: 0 = file on disk, 1 = GAC).
- `MemberType` must be **1** (`DotNetMember_CallMethod`). At the default **0** (`DoNotCall`) the step
  executes as a **silent no-op that still reports `Passed`** — the failure mode that hid the bug above.
- `NameOfMethodToCreate` is a REAL settable property for the adapter's code GENERATION, not the member
  to call. Writing the method name there succeeds and configures nothing.
- Do **not** pre-set `MemberFlags`. Try the untouched lookup first and fall back to the Static bit
  (`1`) only when `IsCallValid` rejects the result; `configure_dotnet_module` does this and reports
  `staticFallbackUsed`. A static member can validate with `Calls[0].Static` still `false`.

#### Member resolution has THREE tiers — the module-level one resolves almost nothing (2026-08-15, issue #37)
`DotNetModule.LoadMemberInfo` + `IsCallValid` — the whole resolution logic until now — only accepts a
member whose prototype it can match without help. Measured on a purpose-built assembly (7-point
signature matrix): with the flags untouched **nothing** resolved, with the Static bit **only bare
`NoArgsVoid()`**; every member with a parameter or a non-void return failed with *"Prototype does not
match that found for member '&lt;name&gt;'"* although the member exists. So a normal method was
unreachable and the step ran as the silent `Passed` no-op above.
- The tier that works is the CALL level: **`DotNetCall.LoadPrototypeFromSignature(nameOrSignature,
  allowMemberNameMatching:true, 0)`** on `Calls[0]` — the API behind the Edit .NET Call dialog. It
  resolved 1- and 2-argument members, non-void returns and `out` parameters, and populates
  `Calls[0].Params`. A member that does not exist returns `false`, so failure stays honest.
- `configure_dotnet_module` runs all three in order (untouched → Static bit → signature) and reports
  **`resolvedVia`** plus the **`signature`** the adapter really bound.
- **`load_module_prototype` runs the SAME three tiers for a .NET step.** The generic
  `Module.LoadPrototype` every other adapter uses does not resolve a .NET member — it throws — so the
  tool used to answer `prototypeLoaded:false` with an empty interface no matter how reachable the
  assembly was. Its documented flows work now: complete a step configured while the assembly was
  missing, or re-sync one whose signature changed. An already-valid interface survives the re-load
  (pinned by `T13`), because the flags are restored and a failed attempt leaves the step as it was.
- **A bare member name picks ONE overload silently** (`Overloaded` → `Overloaded(Double)` with three
  present). Pass the full signature as `method_name` — `"Overloaded(Double, Double)"`, the exact string
  `DotNetAdapter.GetMemberNames` returns — to select a specific one, and read `signature` back. The
  signature form **does** work (issue #37 claims it does not; measured otherwise, `T13`): it SELECTS
  the member, and the step still stores the plain `Calls[0].MemberName` the engine executes off. Use
  the exact `GetMemberNames` spelling — the trailing ` (static)` of the `sigs` list is a display
  suffix, not part of it.
- `GetMemberNames(location, asm, class, options, out names, out sigs)` is the member list: **`options=0`
  = static members + constructors, `options=1` = instance members** — a static member does NOT appear
  at `1`, so a wrong flag looks like a missing member.
- **An INSTANCE member needs `create_object=true`** — alone it is refused (*"is not valid as the first
  call in the invocation because it is an instance member that requires an object"*), and the note now
  names the fix. With it, the step is built as the CALL CHAIN the adapter requires: `Calls[0]` the
  constructor, `Calls[1]` the member invoked on that object. `constructor_signature` picks a non-default one by
  signature, `dispose_object` releases the object afterwards (lands as `CallDispose` on the
  constructor's returned object). `T13` runs one for real: `Triple(4)` on a constructed instance
  writes 12.
  - `Calls` is EMPTY on a fresh step (indexing it throws "Cannot index an empty array"), so the chain
    is built with `Calls.New(i)` + `LoadPrototypeFromSignature` per entry and REBUILT rather than
    patched on a re-configure. The object is handed between entries **implicitly** — there is no
    expression to plumb, and `CreateObject` flips to true by itself.
  - **Calling into an object that already EXISTS elsewhere is not reachable.** Measured both ways:
    `<Use Existing Object>` cannot be loaded by signature (returns false) and
    `DotNetModule.ClassReference` does not persist (reads back empty), leaving the member refused.
    Do not re-investigate without a new idea.

#### A .NET step's parameters live in `Calls[i].Params` (2026-08-15, issue #37)
Never in the flat `Module.Parameters` container — `get_module_parameters` therefore returned `[]` for
every .NET step, however well configured. `Calls` is an ARRAY because one step can chain invocations
(construct → call), so entries are prefixed `<member>.` when there is more than one — which is exactly
what an instance-method step looks like (`InstanceOps.Return Value`, `Triple.a`, …).
- Leaves per entry: `Name`, **`ArgVal`** (the binding expression — for the entry named **`Return Value`**
  it is the DESTINATION the result is written to), `Type` (numeric `DotNetParameterTypes`, e.g. 12 =
  Double), `TypeName` (class/struct/enum only), `Flags`, `IsOptional`, `CallDispose`, …
- **There is no Direction leaf** — direction sits in the `Flags` bits: measured `0` for an input, `6`
  for `Return Value`, `10` for an `out` parameter ⇒ bit `4` = return, bit `2` = output.
- **`set_module_parameter` binds a .NET argument** by its name, or by the `<member>.<parameter>` form
  `get_module_parameters` reports — the only unambiguous address in a call chain, where every entry has
  its own `Return Value`; unprefixed, the first match across the chain wins. Binding `Return Value`
  sets the DESTINATION (`Locals.Sum`). The raw route (`set_step_property` on
  `TS.SData.Calls[0].Params[i].ArgVal`) still works and is equivalent.
- **No "use default" companion flag here** (measured 2026-08-15): the typed `DotNetParameter.ValueExpr`
  writes the same slot as the tree's `ArgVal`, and `UseDefaultValue` neither changes with it nor appears
  in the step tree. So the LabVIEW `UseDefaultValues` asymmetry — the reason `set_module_parameter` is
  unsuitable for a 1:1 rebuild of a pane — does NOT apply to .NET; the writer touches `ArgVal` only.
- `T13` proves the whole chain by RUNNING a step: `Add(2,3)` with its return value bound to a
  StationGlobal reads back 5 (raw route) and `Add(4,5)` → 9 via `set_module_parameter` — the only
  evidence that distinguishes a real call from the no-op.

### Engine lifecycle & file handling
- **Single in-process engine only.** A second engine cannot be torn down cleanly
  while the first one lives → the host hangs on exit. The MCP server uses exactly
  one engine; never spin up a second. (`T01`, see also memory `teststand-testhost-teardown-hang`.)
- **An execution only advances while the ENGINE-CREATION thread pumps Windows messages.** TestStand
  posts progress to a hidden window owned by that thread; the server therefore owns the engine on one
  dedicated, persistent MTA thread running a continuous pump. A pump on any other thread does not work
  (apartment is irrelevant). Do not move engine creation into a transient `Task.Run` — that was the
  original "executions never run" bug. (Memory `teststand-execution-needs-waitforendex-pump`.)
- **Recreating a `.seq` that already exists: `create_sequence_file(overwrite=true)`.** The engine
  releases the OS file handle *asynchronously*, so the close → retry-delete (≈5× / ~300 ms) → create
  dance is required — the tool does it internally now, so there is nothing to open-code. Without
  `overwrite` a pre-existing or still-loaded file fails with a sharing violation, which is the honest
  outcome for an accidental overwrite. A genuine failure (file open in the editor, read-only) surfaces
  with its real reason.
- **Verify persistence by re-opening:** after `save_sequence_file`, call
  `open_sequence_file` again and read back to confirm the write→save→reload round-trip.

### 1:1 file rebuild fidelity ceilings (`T33`; see memory `teststand-1to1-rebuild-fidelity`)
**MOSTLY SUPERSEDED (2026-07-29).** These were the ceilings of the granular per-step approach. Use
`export_sequence_file` + `import_sequence_file` (the imported rebuild rules above) — 9 differences on the reference
file — and read the notes below only when hand-editing.
- **FileDiffer `[val]` vs `{val}`** = an explicitly-set value vs the type-default flag. NO LONGER a
  ceiling: every enum write now resolves the ordinal to its enumerator NAME, which is what stores it
  explicitly. The inverse is the live hazard — writing a value the original leaves at its type default
  flips `{val}`→`[val]`. `get_property_tree` reports `isDefault` per enum leaf so you can tell.
- **Duplicate step names** (multiple `End`/`If`/`Check…`): the by-name step-config tools hit the
  FIRST match only. Use the `Name#N` (Nth occurrence) or `@idx:N` (0-based group index) selectors —
  the rename-and-rename-back dance this used to prescribe is no longer needed.
- **CLOSED, no longer residuals:** number Representation (UInt64) / NumberFormat (now on
  `insert_local_variable` / `insert_sequence_parameter` / `set_property_node`, and readable);
  PropFlags on Locals/Globals/Params members (`set_property_node` `flags` + `clear_flags`);
  a Parameter's default value (`set_property_node` scope=`Parameters`), its comment
  (`set_parameter_comment`) and its nested container members.
- **Still a ceiling:** embedding an UNUSED type definition, a cross-file SequenceCall's cached
  `Prototype` parameter defaults, a step's authored `TS.AdditionalResultsHints` /`CustomResults`
  arrays (use `copy_step_module`), and the enum default marker on a named-type instance's member.

### Enumeration data types (create/modify/delete)
Tools: `create_enum`, `get_enum_values`, `set_enum_values` (bulk replace),
`add_enum_value`, `remove_enum_value`, `rename_enum_value`, `delete_enum`. An enum is a
named numeric data type (name→value constants) stored **in the sequence file**. Values
`{name, value?}`; an omitted `value` auto-assigns C-style (previous+1 from 0); `add` uses
max+1. (`T22`.)
- **An enum is a real named TypeDef, NOT a file-root subproperty.** `NewSubProperty(
  PropValType_Enum)` is rejected ("Unrecognized value") and `UpdateEnumerators` on a plain
  Number throws ("Expected Enumeration, found Number"). Create via `Engine.NewDataType(
  PropValType_Enum)` → set `Name` → `TypeUsageList.InsertType(type, 0, CustomDataTypes)` →
  `SetIsTypeAttachedToFile(idx, true)` (so it persists embedded) → `UpdateEnumerators`.
  Because enums live in the **TypeUsageList**, they do NOT appear in `get_data_types`
  (which lists file-root subproperties); use `get_enum_values`.
- **Write vs read formats differ.** `UpdateEnumerators` takes an ARRAY of containers, each
  with `EnumeratorName`/`EnumeratorValue` (+`OldEnumeratorName` for renames; it REPLACES the
  whole list). But the `Enumerators` getter returns enum-TYPED values — read each one's name
  with `GetValString("", PropOption_CoerceToString=128)` and number with `GetValNumber("",
  PropOption_CoerceToNumber=64)`, else "Expected type String/Number. Found type <Enum>."
- **Use typed interop, never `dynamic`, for `TypeUsageList`/`PropertyObject` here.** The C#
  dynamic-COM binder throws `TargetParameterCountException` on `GetTypeDefinition` and
  mis-binds others. A `var tul = ...` off a `dynamic sf` silently re-poisons the chain.

### Authoring-complete step editing (1:1 file rebuilds; `T31`/`T32`)
- **`create_step_property`** creates NEW subproperties on a step by dotted path:
  `number`/`boolean`/`string`/`container`/`reference` (Object Reference), `named_type`
  (+`type_name`, e.g. `SequenceArgument`, `ErrorDialogOptions`, `Error`), and
  `array_elements` (+`num_elements`) which creates/resizes typed arrays — elements are
  instantiated with the array's ELEMENT type (authors `TS.SData.ViCall.Parms`,
  `…Parms[i].ArrayClusterEls`, `TS.AdditionalResultsHints`, `Result.TimeoutOccurred`).
  Named types resolve engine-wide (fallback `Engine.NewPropertyObject` +
  `SetPropertyObject(PropOption_InsertIfMissing)`); requesting a named type on an
  existing node of a DIFFERENT type RETYPES it in place. Idempotent otherwise.
- **`set_step_property_flags`** sets raw PropFlags (SetFlags) on any step property —
  e.g. `0x4` PassByReference on Prototype members, `0x200000` module marker.
- **`rename_step_property`** sets a step property's NAME (PropertyObject.Name).
  **Array elements can be NAMED** — ViCall.Parms entries carry the connector-pane label
  as their element name, the editor/FileDiffer display them as `[i] Name` and **pair
  array elements BY that name**. `create_step_property(array_elements)` creates elements
  unnamed → always set each element's name afterwards, or the differ shows the whole
  array as same-named Delete/Insert pairs despite identical content. `get_property_tree`
  reports element names via the node's `elementName` field.
- `set_step_property`/`create_step_property` accept `unescape:true` to decode
  `\r \n \t \\ \uXXXX` — the only way to write bare control chars (VIDescriptions with CR).
- `insert_file_global`/`insert_local_variable` accept `'reference'` (Object Reference)
  and named custom types; there is NO silent String fallback anymore.
- `set_module_parameter` binds LabVIEW connector-pane parms by Label (`'error out.status'`
  descends into clusters; writes ArgVal + clears UseDefaultValues) and, for SequenceCall,
  binds `ActualArgs.<name>.Expr` + clears that arg's `UseDef`.
  `get_module_parameters` reads ViCall.Parms / VIModule.ViCall.Parms / ActualArgs.
- **Prototype auto-load on module config (ALL adapters):** every typed module-config tool now runs
  `Module.LoadPrototype(0)` (the engine's "Load Prototype") **after** it sets the target — so the
  step's parameter interface is populated in one call: `configure_labview_module` (VI connector
  pane → `ViCall.Parms`), `configure_dll_module`, `configure_dotnet_module`, `configure_python_module`
  (function prototype → `Module.Parameters`) and `configure_sequence_call_module` (callee args →
  `TS.SData.ActualArgs`). `set_sequence_call_target` / `insert_steps_bulk` also load the SeqCall
  prototype; `set_module_parameter` loads it when the named arg is missing. **Order matters** — the
  load is centralized in `ConfigureModuleAsync` to run strictly after the VI-path/target is set;
  without it the interface stays empty. For SequenceCall the load also enforces `UseDef ⇔ empty Expr`
  (unbound args `UseDef=True`, bound `False`) — matching a genuine call for the FileDiffer. All five
  configure tools now RETURN the loaded interface in the result's **`parameters`** list, and each
  takes an optional **`load_prototype`** (default `true`) to skip the load when the target is not yet
  reachable. Unresolvable targets (unlinked placeholder / missing or not-yet-loaded file / a VI in an
  unloadable `.lvlibp` headless) skip silently — so the target must be loadable (loaded or on the
  search path) for the interface to materialise headless.
- **`load_module_prototype`** — adapter-agnostic standalone tool = the editor's "Load Prototype"
  button on any step (LabVIEW / DLL·CVI / .NET / **ActiveX** / SequenceCall). Two uses: (1) after a
  `configure_*` with `load_prototype:false`, once the target is reachable; (2) **RE-SYNC a caller
  after the target's own interface changed** — e.g. a subsequence's Parameters were edited, or a
  DLL/VI/ActiveX signature changed — so the caller's arguments match again. Does NOT change the
  adapter; non-destructive (existing bindings matched by name). Returns `{stepName, adapter,
  prototypeLoaded, note, executionMode, workerOutcome, parameters[]}` — `prototypeLoaded:false` + a
  `note` when the target could not be resolved. (New tool NAME → needs a fresh MCP session to appear
  in the catalog after rebuild.)
  - **ASYNC + ExecServer-routed worker by default (2026-07-09; see [[teststand-loadprototype-lvlibp-crash-isolation]]).**
    A LabVIEW load attaches to/starts LabVIEW — the SAME slow work the editor's "Reload Prototype"
    does — and can exceed the MCP transport's ~60s window (`-32001`). So a LabVIEW load runs
    **asynchronously by default**: `load_module_prototype` returns immediately with `{jobId,
    status:"running"}`; poll **`get_prototype_load_status(job_id)`** until `status:"completed"`.
  - **ROOT CAUSE + the real fix (from the NuGet `…Interop.AdapterAPI`).** Headless, with no explicit
    server, the LabVIEW adapter's **AutoDetect** resolves a LabVIEW **Run-Time** (`lvrt.dll`) that
    can't be bound in-process → the delay-load SEH `0xC06D007E`. The editor works because it uses the
    running LabVIEW **development** environment (**ExecServer**, ActiveX — no RTE delay-load). So before
    the load we now **route the adapter to the ExecServer** and connect: `GetAdapterByKeyName(key)` →
    **cast to the typed `LabVIEWAdapter`** (the `Initialize`/`Get`/`SetServerInfo` methods live on THAT
    interface, NOT the generic `Adapter` dispinterface — which is why an earlier late-bound
    `dynamic adapter.Initialize()` silently no-op'd) → `SetServerInfo(ExecServerDeferred,"LabVIEW")` +
    `Initialize()`, restored afterward. Configurable via **`labview_server`**: `deferred` (default,
    running ADE launched on first use), `exec` (connect now), `rte` (legacy AutoDetect), `auto` (leave
    config untouched).
  - **NEITHER `isolate` setting loads a packed-library VI — and the fatal one is now REFUSED
    (measured twice, 2026-07-29; guard added 2026-07-30).** `isolate:true` (the default) is a separate
    process that does not inherit the attachment to the running LabVIEW ADE, starts its own and TIMES
    OUT (8 steps × 120 s, all timeouts). It also reads the file from DISK, so a load after `save:false`
    edits reports the step as out of range — which reads like an unloadable VI but is an unsaved file.
    `isolate:false` (in-process) **KILLED THE SERVER**: it raised `0xC06D007E`, the MSVC delay-load
    fault for the LabVIEW Run-Time, with LabVIEW 2026 32-bit already running and responsive; the fault
    escapes managed `try/catch` and the in-process path has no guards. An earlier note here recommended
    `isolate:false` on the strength of one apparently-good run — that recommendation caused a server
    crash and an NI Error Reporter dialog, and is retracted. **The combination now throws instead**
    (`force_unsafe_inprocess:true` to override, which only reproduces the crash). What the worker still
    buys is crash containment for a non-packed VI (`prototypeLoaded:false`,
    `workerOutcome:"crashed"`/`"timeout"`, server lives).
    **`copy_step_module` is not the fallback — it is THE way.**
  - **SILENT worker death — no WER box AND no NI Error Reporter dialog.** `SetErrorMode` alone only
    hides the OS fault box; NI's green "…encountered a problem and needs to close" reporter is an
    IN-PROCESS unhandled-exception hook. The worker installs layered guards up front (in
    `LoadPrototypeWorker.InstallSilentDeathGuards`): the decisive one is a **vectored exception handler**
    (`AddVectoredExceptionHandler(first=1)`) that, on the MSVC delay-load SEH family (`0xC06Dxxxx` —
    high word `0xC06D`, so it never fires on ordinary handled C++/CLR exceptions `0xE06D…`/`0xE0434352`),
    calls `TerminateProcess` DURING first-chance dispatch — before any frame-based/unhandled handler,
    i.e. before NI's hook can start the dialog. Plus `SetErrorMode`, `WerSetFlags(NO_UI)` +
    `WerAddExcludedApplication`, CRT `_set_abort_behavior(0,…)`, and a `SetUnhandledExceptionFilter`
    backstop for other fatal faults. Verified: a raised `0xC06D007E` dies in ~4s (not a timeout) with
    ZERO lingering `WerFault.exe`/NIER processes, and the real load still returns `not-loaded` cleanly
    (the VEH does not false-fire on the handled path). Test hook: env `TESTSTAND_MCP_LP_SIMULATE_CRASH`
    = `raise` (RaiseException → exercises the VEH) or `1` (direct TerminateProcess). The worker is
    bounded by `timeout_seconds` (default 120; on expiry its process tree is killed →
    `workerOutcome:"timeout"`); on success it SAVES to disk and the parent reloads it.
  - **Params & result.** `async` (default true for LabVIEW / false otherwise), `isolate` (default
    true), `labview_server` (default `deferred`), `timeout_seconds` (default 120). Non-LabVIEW adapters (SequenceCall/.NET/DLL·CVI/ActiveX)
    always run fast, **in-process, synchronously** — no behaviour change, no regression. Result carries
    `executionMode` (`in-process`|`worker`), `workerOutcome`, `jobId`, `status`. NOTE: the auto-load
    inside the `configure_*_module` tools still runs in-process synchronously — use `load_prototype:false`
    + `load_module_prototype` (async) or `copy_step_module` for a `.lvlibp` there. New tool NAME
    `get_prototype_load_status` + the `async` param → need a fresh MCP session after rebuild.
- With element names mirrored, a full tool-driven rebuild of TFW_DemoModule.seq
  diffs **identical (0 differences)** against the original (`T32`).

### 1:1-rebuild tool-gap batch (2026-07-07)
Closed the residual gaps found rebuilding `TFW_MCP_Test.seq`. All verified live except where noted.
- **Enum leaf reads** — `get_file_globals` / `get_property_object` / `get_property_tree` return an
  enum leaf as `valueType:"Enum"`, `value:{ordinal, symbolicName}` (a plain read throws on enums, so
  they used to come back `Unknown`/`Empty`/`0`). NUANCE: a value set by raw ORDINAL reads back with
  an empty `symbolicName` until reload; set by NAME (or the authored default) keeps it — the ordinal
  is always right.
- **`value_type='enum'`** on `set_property_value` (+ new `type_name`) and `create_step_property`
  (`type_name` existed): creates the member as an instance of the named enum typedef and sets its
  ordinal/name (CoerceToEnum) — so an enum container-member gets its real type, not an anonymous
  container. NEW enum values/params ⇒ need a fresh MCP session (see caveat below).
- **`set_file_global`** now types a boolean correctly (was writing "true"/"false" as a String →
  never persisted); it PRESERVES an existing global's authored type. NEW **`set_file_global_comment`**
  (FileGlobals twin of `set_local_variable_comment`; dotted path reaches container members).
- **`compare_sequence_files` DEFAULTS to `mode='native'`** (the authoritative FileDiffer, ==
  `diff_sequence_files`). Use it to VERIFY a rebuild. `mode='structural'` is the old fast in-process
  compare — now self-labelled (`fidelity`/`note`); its `totalDifferences==0` does NOT prove identity.
- **`@idx:N` step selector** (0-based group index) added alongside `Name#N`; works in EVERY by-name
  step tool (`set_step_*`, `set_module_parameter`, `configure_*`).
- **`set_step_property` auto-detect peeks the target type first** — writing "True"/"False" to a
  String expression prop (`ActualArgs.<arg>.Expr`, any `*.Expr`) stays a String (no more "Expected
  Boolean, found String"); string set also retries CoerceToEnum for enum-by-label.
- **Nameless `Label`** (empty name = blank spacer) auto-gets `TS.Icon="ni_blank.ico"` + step flag
  `0x4000000` on insert (named labels keep `label.ico`); bulk now allows an empty name for a Label.
- **Action step calling a subsequence** — set adapter `Sequence` (via `change_step_adapter` or
  `insert_step`/`insert_steps_bulk` `adapter='Sequence'`), then `configure_sequence_call_module`
  (works on ANY Sequence-Adapter step; the step keeps its `Action` type).
- **Comment/description encoding is Windows-1252, NOT lossy for `–`/`—`/`…`/`•`/`€`/`™`/curly quotes**
  — those SURVIVE a round-trip; only truly-non-1252 chars (`→` `✓` emoji/CJK) become `?`. The guard
  was over-warning (checked `≤0xFF`); now Windows-1252-accurate. (This branch uses a hardcoded
  1252-extras table; another branch fixed it via `WideCharToMultiByte` — prefer that on merge.)
- **CAVEAT — the MCP client validates args against the schema cached at session start.** New tool
  NAMES *and* new ENUM VALUES / optional PARAMS (`value_type='enum'`, compare `mode`,
  `set_property_value` `type_name`, the `Sequence` adapter) only appear after a FRESH session; before
  that they are rejected with `invalid_enum_value`. Rebuild the server, then start a new session.

### 1:1-rebuild tool-gap batch — wave 2 (2026-07-07)
Closes the P1 analyzer errors and the LabVIEW-metadata diffs.
- **Nested member with a named/enum type — `set_property_value value_type='named_type'` (+`type_name`)**
  creates a member as a FULL instance of a file-defined type (a container like
  `TFW_DB_TestCasesLimits` / `VisionSensorSbsi_Reply_Payload` / `Error`, or a named leaf),
  MATERIALISING the type's fields (like the editor) via `Engine.NewPropertyObject(NamedType)` +
  `SetPropertyObject(InsertIfMissing)` — so afterwards you only set the fields that differ. This is
  the ONLY way a nested container member gets its named type instead of an anonymous `Container`
  (the cause of every `NI_ExpressionEvaluationError "Expected <Type>, found Container"`).
  `value_type='enum'` (+`type_name`) creates an enum leaf inside a container — pass its value as the
  new **`ordinal`** param (numeric, preferred) or `value` (ordinal or symbolic name). Same on
  `create_step_property`. **Recipe:** `copy_typedefs` first (so the type exists), then
  `set_property_value(named_type)` for each typed container member, then set only the non-default
  fields; enum leaves via `value_type='enum'` + `ordinal`.
- **LabVIEW `.lvlibp` module metadata — `copy_step_module`.** VIs in a packed library can't load
  headless, so `load_module_prototype` returns `prototypeLoaded:false` and the connector pane
  (`ViCall.Parms`, Namespace, VI Description, Connector-Pane-Checksum) cannot be regenerated. Instead,
  **copy the cached module subtree from the SOURCE `.seq` step** onto the rebuilt step:
  `copy_step_module` deep-copies `TS.SData` (a SequenceCall's ActualArgs, a RunVIAsync's
  `SeqCallStepAdditions` incl. `Parameter0..3`, an adapter module) + the step-own `VIModule`
  (ViCall metadata), and aligns the adapter — no LabVIEW needed. Run
  `copy_typedefs` first. **(2026-07-08 fix — see [[teststand-copystepmodule-clone-fix]]):** each
  subtree is now `PropertyObject.Clone(path, 0x20000000 PropOption_CopyAllFlags)`d BEFORE
  `SetPropertyObject` — a live source object still has a parent and TestStand rejects it ("already
  has a parent object. You must first clone the item"), which had made `copiedPaths` come back empty.
  It ALSO clones the authored step-config subtrees a fresh insert doesn't instantiate from the
  step-type template — `TS.AdditionalResultsHints`, `TS.CustomResults`, `TS.ErrorDialogOptions`,
  `Result.TimeoutOccurred` (each copied only if present on the source) — so a NON-adapter step like
  an `NI_Wait` reproduces faithfully too (its wait TARGET still needs `configure_wait`, as that lives
  in step-root props, not `TS.SData`). Verified: rebuilding only `Init`+`Close` of
  `TFW_Symphony_EOL.seq` diffs 0 under both sequences incl. all three `.lvlibp` LabVIEW steps.
  (Reading a VI's connector-pane bindings: `get_module_parameters` returns
  Label→ArgVal per parameter; the VI-level metadata reads via `get_property_tree` scoped with
  `lookup_string` to the step's `…ViCall` — scope it, don't dump the whole `TS` at low depth, or the
  node budget truncates it.)
- **`set_step_property` now resolves `Icon` and `Flags`.** `property_path='Icon'` → `TS.Icon` (the
  step icon file, e.g. `ni_blank.ico`); `property_path='Flags'` → the step's flag bitfield via
  `SetFlags` (decimal or `0x`-hex, e.g. `0x4000000` to blank a nameless Label's icon). Previously both
  errored "Unknown variable or property name". (Nameless-Label auto-blanking + bulk empty-name Label
  landed in wave 1.)

### 1:1-rebuild tool-gap batch — wave 3 (2026-07-09): scope-generic property-tree CRUD
Closed the last write/delete/flag gap on the **`Parameters.*`** level (and nested submembers under
any scope). The read side already had `get_property_tree`; these are the symmetric writers. Both are
**scope-generic** — `scope` ∈ `Parameters | Locals | FileGlobals | StationGlobals | SequenceFile`.
See memory `teststand-property-node-crud-2026-07-09`.
- **`set_property_node`** — create/set a node (and optionally its PropFlags) at a dotted
  `lookup_string` relative to the scope root. Reuses the SAME creation switch as `set_property_value`
  + `create_step_property` (`number/string/boolean/container/reference/named_type/enum/array_elements`):
  `named_type` (+`type_name`) instantiates a FULL typed instance (fields materialise, like the editor,
  via `Engine.NewPropertyObject`+`SetPropertyObject(InsertIfMissing)`) so a container member gets its
  real type instead of an anonymous `Container`; `enum` (+`type_name`, value via `ordinal` preferred)
  resolves ordinal→enumerator NAME so it stores explicit `[val]` (matches the editor-authored original,
  no spurious `{val}` diff); `array_elements` (+`num_elements`) sizes a typed array. Missing
  intermediate containers auto-create (`create_missing_parents`, default true). `flags` applies raw
  PropFlags via `SetFlags` (OR semantics — e.g. `132`/`0x84` = `0x04` PassByReference + `0x80`). A value
  is written only when supplied → a **flags-only** call never clobbers the value (closes the
  Local/Parameter-submember PropFlags residual, e.g. `Job1.SetJob_Reply_Payload` `0x4` vs `0x0`).
- **`delete_property_node`** — the missing `delete_sequence_parameter`, generalised. `scope=Parameters`
  + a top-level name removes a whole parameter (+ its structure); a nested `lookup_string`
  (e.g. `MDC_cmd.Request.Cmd`) surgically removes one submember. The scope-generic counterpart of
  `delete_sub_property` (Locals/FileGlobals only). `DeleteSubProperty` accepts a dotted path, so both
  forms are one call.
- **Roots per scope:** `Parameters`/`Locals` → `Sequence.Parameters`/`.Locals` (need `sequence_name`);
  `FileGlobals` → `FileGlobalsDefaultValues`; `StationGlobals` → `Engine.Globals` (commits via
  `CommitGlobalsToDisk`, `file_path` unused); `SequenceFile` → `AsPropertyObject()`.
- **Verified end-to-end** rebuilding the anonymous-container parameter `MDC_cmd` of `_MDC_com`
  (`TFW_MDC_com_Python.seq`): the 3 target diffs (Flags, Request subtree, Response subtree) drop to 0
  with **zero** newly-introduced diffs; enums reproduce identical (`[Command] (0)` /
  `[GetKfMdcProtocolVersion] (4629)` / `[GetHousingTemperature] (4630)`). New tool NAMES → need a
  FRESH MCP session to appear in the catalog after the rebuild.
