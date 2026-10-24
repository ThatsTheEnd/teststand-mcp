---
name: teststand-rules
description: Rules for ANY work on NI TestStand sequence files through the TestStand MCP tools - building sequences from a flowchart or description, inserting and editing steps, flow control (If, loops, Select/Case), rebuilding, migrating or cloning .seq files, comparing and verifying files, LabVIEW .lvlibp steps, documenting or presenting a sequence, running sequences headless, the sequence analyzer, and the teststand-sequence-builder, teststand-doc-generator and teststand-presentation-generator agents. Load it before the first TestStand tool call.
---

# TestStand rules

## Never do

- Never run the `teststand-sequence-builder` as a subagent. Run its workflow in the main thread: its per-step `AskUserQuestion` prompts do not work in a subagent, and every step silently degrades to a plain Statement placeholder.
- Never use `Goto` or `Label` for control flow. Use the `NI_Flow_*` step types (`NI_Flow_If`, `NI_Flow_While`, `NI_Flow_For`, `NI_Flow_Select`, ...): they are structured and survive later edits.
- Never load a `.lvlibp` pane in-process. Clone it from a source `.seq` with `copy_step_module` or the `import_sequence_file` default; an in-process load can kill the server.
- Never accept a rebuild on the diff alone. Run `diff_sequence_files` for the content AND `audit_type_consistency` for the type registry; the diff cannot see type conflicts.

## Details

- [references/rebuild.md](references/rebuild.md) - rebuilding, migrating and cloning `.seq` files, file format, `.lvlibp` panes, verification.
- [references/sequence-design.md](references/sequence-design.md) - flow-control structure, Select/Case blocks, default step type, step types.
- [references/agents.md](references/agents.md) - building from a flowchart, the documentation and presentation generators.
- [references/headless-and-tools.md](references/headless-and-tools.md) - headless limitations, variables and expressions, validation, analyzer, live debugging, environments.
