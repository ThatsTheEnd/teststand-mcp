# Fork rehearsal, 2026-10-25

The release path ran end to end in the throw-away public fork `ThatsTheEnd/teststand-mcp` before
PR A, so the real repository never carries an unusable release. A fork-only commit (never merged)
pointed the manifests, the release-repo constant and the tests that pin it at the fork.

| Step | Run | Result |
|---|---|---|
| `ci.yml` on push to main | 40179392382 | Pass in 11 min on windows-latest without TestStand: 46 engine-free tests; 26 script runs (13 suites under Windows PowerShell 5.1 and PowerShell 7, none skipped); 125 stats tests; packaging `0.0.0-ci` verified, archive kept as an artifact. |
| Dry run, no fault | 40180221039 | **Fail, real bug**: the verifier threw when the repository held exactly one release (a one-element list unrolled to a single object, `.Count` throws under strict mode on 5.1). Cleanup still deleted the draft. Fixed in `fix: read a release list that holds a single release` with a test. |
| Dry run, no fault (after the fix) | 40180606884 | Pass: draft created, verified through the API (4 assets, all uploaded by github-actions[bot]), deleted; no tag left. |
| Dry run, `corrupt-zip` | 40180809842 | Fails as intended at the listing check (versioned archive 76 MB, plugin archive 15 bytes); nothing published; draft deleted. |
| Tag push `v1.9.0` | 40181030639 | Pass: verified draft published by release id, marked latest; the public `releases/latest` download matched the verified archive. |
| Tag push `v1.9.1` | 40181470202 | Pass; latest moved to `v1.9.1`. |
| `pages.yml` by hand | 40181725594 | Collect passes and commits `downloads.csv`, `own-downloads.csv`, `traffic.csv` to the `stats` branch; the own-downloads artifacts of the three verified release runs were accepted; traffic skipped (no token). Deploy fails only because the fork's Pages source is not set to "GitHub Actions", as designed. |

## Install check (AC-10) in an isolated profile

`CLAUDE_CONFIG_DIR` pointed at a fresh folder, with Claude Code 2.1.310. The maintainer's own
registration and plugin files were hash-checked before and stayed untouched.

- Before installing, `claude mcp list` showed no server: `CLAUDE_CONFIG_DIR` also hides the user-scope
  MCP registration (closes the open half of fact 13).
- `claude plugin marketplace add ThatsTheEnd/teststand-mcp` and
  `claude plugin install teststand-mcp@zuehlke-teststand`: installed 1.9.0 in 17 s. The install names
  the unset optional `tsenv_path` ("1 userConfig option not yet set").
- `claude mcp list`: `plugin:teststand-mcp:teststand ... Connected`.
- Installed tree: manifest, `.mcp.json`, `VERSION.txt` (tag, version, commit, built, run URL),
  3 agents, the skill, hooks, 619 files in `bin`. `--version` reports 1.9.0, tag and commit.
- Hooks run exactly as `hooks.json` starts them (exec form, 0.35 to 0.75 s each): the allow hook allows
  `get_steps` on a `.seq` inside the project and stays silent for a UNC path and for `insert_step`;
  the platform guard reports the station's real missing Pillow plus the rules pointer; the update notice
  is silent while installed equals latest.
- The four engine flows through the installed exe: `initialize` in 288 ms, `connect_engine`, open a
  file, the isolated worker (`worker`/`not-loaded`), an execution to `Passed`; the loaded
  `coreclr.dll` is the one in the plugin's own `bin`.

## Update check (AC-12, AC-13)

- With 1.9.0 installed and `v1.9.1` latest, the update-notify hook printed one message naming both
  versions, the two commands in order and "restart Claude Code"; a second run the same day was silent.
  (The 24 h lookup cache from the earlier run was deleted in the test profile to see it at once.)
- `claude plugin marketplace update zuehlke-teststand` then `claude plugin update teststand-mcp`:
  "updated from 1.9.0 to 1.9.1"; `claude mcp list` connects from the `1.9.1` cache folder; the `1.9.0`
  folder is kept.
- **Not verified:** marketplace auto-update itself. It runs only inside an interactive session after a
  random delay (fact 4), so it needs a person in a real session.

## Found on the way

- **Long profile paths break the marketplace clone.** From a very long `CLAUDE_CONFIG_DIR` the clone
  failed with `fatal: '$GIT_DIR' too big`; from a short path it worked. Worth one troubleshooting line in
  the README.
- **The pre-push hook stops the dev server.** `.githooks/pre-push` force-stops every `TestStandMCP.exe`
  and `SeqEdit.exe` and runs the integration suite; the fork pushes used `--no-verify` with the
  maintainer's approval.
- **Draft downloads (AC-18 measurement): still open.** Right after the rehearsal every asset reported
  `download_count` 0, including the two plugin installs and the public `latest` fetches, so GitHub's
  counter lags. Re-read the counts later before deciding `SUBTRACT_DRAFT_DOWNLOADS`.

## Second round, after the backstop review fixes (2026-10-25)

The fixes moved the draft creation, the publish decision and the rehearsal cleanup out of the
YAML into tested scripts (`New-ReleaseDraft.ps1`, `Publish-Release.ps1`,
`Remove-RehearsalRelease.ps1`), which until then had run only against a fake `gh`. The branch was
merged into the fork branch and run again:

| Step | Run | Result |
|---|---|---|
| `ci.yml` on push | (run of e900794) | Pass in 11 min. |
| Dry run, no fault | 40190471705 | Pass: draft verified, then deleted by its own id; no tag left. |
| Dry run, `corrupt-zip` | 40190667906 | Fails as intended at the listing check; nothing published; this run's draft deleted. |
| Tag push `v1.9.2` | (run after the tag) | Pass: verified, published by id, marked latest (`v1.9.1` was latest before); no stray drafts. |

Running the suites against the fork also exposed one test that called the real GitHub API: the
`-Latest -Repo` argument row passed only because `Zuehlke/teststand-mcp` has no plugin archive yet,
so CI would have turned red with the first release. It was removed
(`test: no live GitHub call in the verifier argument checks`).
