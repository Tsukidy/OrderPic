# Retrospective: gallery-upload-option

> Written: 2026-09-12 (after verify passed with one operator-gated warning)
> Commit range: `013114b..40943c1`
> Worktree: `.claude/worktrees/gallery-upload-option` (branch `worktree-gallery-upload-option`, not yet merged)

---

## 0. Evidence

- **Commit range**: `013114b..40943c1` (23 commits)
- **Diff size**: +3101 / −237 lines across 18 files (4 lib, 3 test, CLAUDE.md, 10 change artifacts, 4 tasks.md flips)
- **Tasks done**: 10/11 (`grep -cE '^\s*- \[x\]' tasks.md` → 10; 5.2 device pass is operator-gated)
- **Active hours**: ~4 (single working session, 2026-09-11 21:05 → 2026-09-12 00:50 UTC), including environment provisioning
- **Subagent dispatches**: 19 (10 implementer-class: 7 plan tasks + 1 fix-round resume + 1 5.1 gap addendum + 1 final-review fix wave + 1 docs; 9 review-class: 6 task reviews + 1 final whole-branch + 1 scoped fix re-review + 1 gate) — first cycle of this repo to run the schema's subagent-driven apply phase
- **New external dependencies**: none
- **Bugs encountered post-merge**: none (not yet merged; all findings landed pre-archive)
- **OpenSpec validate state at archive**: not-run yet (archive pending 5.2)
- **Test coverage signal**: 173/173 widget+unit tests (up from 146 at change start), `flutter analyze` clean

Commit chain (時序, summarized):

```
013114b (main) folder-bundling archived — baseline 146 tests
abc6dfd chore: change artifacts for gallery-upload-option
9ee3208 feat: extension-contract guard — re-encode non-JPEG gallery sources under .jpg names
844214f feat: CameraPage source parameter — gallery multi-pick admission
669223a test: multi-pick cancel/throw + batch-independence contract pinned
e46877b feat: QR confirm offers Take photo / Gallery
17814a5 feat: manual entry confirms Take photo / Gallery
ddeebbb feat: Add photo opens a Take photo / Choose from gallery sheet
9f808c3 fix: the Add-photo sheet disarms the upload gate at open, not at choice
64090b9 feat: done-state continuations offer the source choice
499ced0 test: single-shot multi-pick review contract pinned
cb06e69 test: single-shot done row gallery choice pinned (5.1 walk gap closure)
b97e15b docs: gallery capture source
9ece12b docs: final-review text fixes — retake scenario wording, processor doc, CLAUDE.md guard
40943c1 chore: verify — gallery-upload-option (10/11, one operator-gated task)
```

---

## 1. Wins

- [evidence: 013114b...HEAD lib diffstat — 4 lib files, `uploader.dart`/`session.dart`/`naming.dart`/`history_page.dart` untouched] The folder-bundling bet paid off exactly as proposed: source-agnostic `admitPicked` made the gallery a pure entry-points-plus-guard change; folder placement and History needed zero code.
- [evidence: commit 844214f; ruling 3 in the SDD ledger] Pinning the fake to the installed delegation chain (`getMultiImageWithOptions`, image_picker_platform_interface 2.11.1) before writing tests produced zero plugin drift — the reviewer verified the delegation in the pub cache and the fake's signature matches to the default value.
- [evidence: commit 9ee3208; test/image_processor_test.dart copy-path test] The magic-byte sniff converts the worst failure mode (a HEIC silently uploaded under a `.jpg` name, unopenable on Windows) into the existing flagged-retake path — and the review caught that the PRE-EXISTING copy test's fixture was never JPEG-headed, i.e. the guard is provably live.
- [evidence: commit 9f808c3 + the mid-sheet settle pin suite] The per-task review loop caught a genuine design gap the plan missed (armed upload gate × sheet-open window → auto-upload under the sheet → session dir reclaim under new admissions) before any code merged, and the ruling got a functional regression pin, not just a fix.
- [evidence: final review Important #1 + fix commit 9ece12b] The final whole-branch review caught the delta-spec Retake scenario contradicting D10 BEFORE archive sync would have made the unexecutable scenario permanent main-spec contract.
- [evidence: ledger, autoFixOrientation ruling] A parked concern from Task 1's review ("re-encode may output sideways") was CLOSED by reading the installed plugin source — `autoCorrectionAngle` defaults true and EXIF orientation is baked — instead of shipping a speculative flag that would have deviated from D8 for no behavioral gain.

## 2. Misses

- 🟡 [evidence: plan.md has no Task 2.2 section; tasks.md 2.2 text duplicates 2.1's Step 1] tasks.md and plan.md diverge in numbering/granularity (11 vs 10 sections) — the controller had to rule mid-flight on what 2.2's residual scope was. Cost: one extra ledger ruling + a hand-written brief file.
- 🟡 [evidence: commit ddeebbb → 9f808c3] D4 (bottom sheet) was designed without considering the armed-upload-gate interaction; the race surfaced at the implementer's DONE_WITH_CONCERNS and cost one fix round. The design doc's Risks section should have brainstormed "what can settle while the sheet is open".
- 📌 [evidence: ledger Task 1 deferred minor → final review Minor #2] The stale `ImageProcessor.process` doc was deferred as a minor at task 1 and survived to the final review, which then mandated it. Deferring doc-of-contract findings costs more than paying them.
- 📌 [evidence: 11 `chore: tasks.md` commits in the chain] Checkbox flips are separate commits — traceable but noisy; folding them into the next task commit would halve the chore count.
- 📌 [evidence: session log 21:07–21:20 UTC] Environment provisioning burned ~15 min: no Flutter SDK on this machine, the first extraction script's mtime-based `find -newer` check deleted its own successful extraction (tar preserves archive mtimes), and root-owned `~/.config` needed the legacy `~/.flutter_settings` workaround until the user fixed ownership.

## 3. Plan deviations

| Plan task | What changed | Why |
|-----------|--------------|-----|
| 2.1/2.2 split | 2.1 delivered all of 2.2's named test scenarios; 2.2 re-scoped to the batch-independence pin + formatting fix | tasks.md 2.2's text duplicates 2.1's brief Step 1 verbatim; controller ruling avoided duplicating suites |
| 2.1 "maxWidth:, maxHeight:, imageQuality" | multi-pick passes maxWidth + imageQuality only | today's camera call never passes maxHeight; D7's "same mapping" read as mirroring the actual param set (reviewer-verified, test-pinned) |
| 3.1 "`_ConfirmedSource { camera, gallery }`" | dialogs return `CaptureSource?` directly | plan said "e.g."; one fewer 1:1 mapping enum, same shape |
| 3.1/3.2 "test/home_page_test.dart-style harness" | suites landed in `test/camera_cancel_test.dart` (the scanner's `_onDetectOf` harness) | plan explicitly allowed "or the scanner's existing harness" |
| 5.1 | run in-session by the controller (gate + requirement walk) instead of dispatched | controller already held all spec + review context; a dispatch would have re-pasted it |
| 5.2 | not executed | requires a physical device + LAN share — absent in this environment; operator-gated, gates archive |
| Environment | Flutter SDK installed (3.47.4 stable) as part of apply pre-flight | plan assumed a working toolchain; none existed on this machine |

## 4. Skill / workflow compliance

| Skill                                            | Used |
|--------------------------------------------------|------|
| superpowers:brainstorming                        | ✓ (prior session — brainstorm.md artifact) |
| superpowers:writing-plans                        | ✓ (prior session — plan.md artifact) |
| superpowers:using-git-worktrees                  | ✓ (EnterWorktree native tool, per skill Step 1a) |
| superpowers:subagent-driven-development          | ✓ (first full run in this repo: 19 dispatches, ledger-driven) |
| (transitive) superpowers:test-driven-development | ✓ (every implementer dispatch carried RED→GREEN evidence; the two pinning tasks documented why RED is n/a) |
| (transitive) superpowers:requesting-code-review  | ✓ (6 task reviews + final whole-branch review + scoped fix re-review) |
| superpowers:finishing-a-development-branch       | ⏳ pending — sequenced after retro + archive by the apply instruction; not skipped |

> **Default expectation**: 全部 ✓。任一項 ✗ 都必須在下方 `### Deliberately Skipped Skills` subsection 提出原因與預防方案。No ✗ this cycle — finishing-a-development-branch is pending by design, not skipped.

### Deliberately Skipped Skills

(none — expected state)

## 5. Surprises

- This machine had NO Flutter SDK and no `/home/dylan` (CLAUDE.md's SDK path is from a different machine); stable 3.47.4 had to be installed as apply pre-flight. The Bash harness also refused inline `XDG_CONFIG_HOME=` (worktree git-isolation guard), and `~/.config` was root-owned — solved via flutter_tools' legacy `~/.flutter_settings`/`~/.flutter_tool_state` fallback (config.dart honors them over XDG), then removed once the user fixed ownership.
- The parked "autoFixOrientation" concern was factually wrong about the installed plugin: the parameter is `autoCorrectionAngle`, it defaults to true, and EXIF orientation is baked into re-encoded pixels (HEIF-aware via androidx ExifInterface). Reading the dependency's actual source beat a plausible-sounding review claim.
- tar extraction + `find -newer` don't compose (tar restores archive mtimes): a "cleanup" guard deleted a successful extraction. Cost: one re-extract of 1.58 GB.
- Subagent shells did not inherit the controller's PATH assumptions — the Task 3 implementer hit "flutter: command not found" despite a dispatch note saying it was on PATH; absolute SDK paths fixed it.
- `dart format` is no longer a safe no-op on this repo: Flutter 3.47's tall style would rewrite 19/30 files (the project predates 3.7 short style). Formatter runs are now a deliberate repo-wide decision, not a hygiene reflex.

## 6. Promote candidates → long-term learning

- [ ] 📌 **This machine's Flutter toolchain lives at `/home/coder/flutter` (not CLAUDE.md's `/home/dylan/...` path)** → **Promote to memory** (type: project)
  > **Why**: CLAUDE.md's SDK path comes from the machine the repo was developed on; this machine had none and one was installed 2026-09-11 during gallery-upload-option apply.
  > **How to apply**: any session on this machine that needs flutter/dart — invoke `/home/coder/flutter/bin/flutter` (subagent shells do not have it on PATH).

- [ ] 📌 **Never run a blanket `dart format` on this repo** → **Promote to memory** (type: project)
  > **Why**: the codebase is formatted pre-Dart-3.7 short style; Flutter 3.47's tall style would rewrite 19/30 files and swamp feature diffs (ruled in gallery-upload-option Task 2.2).
  > **How to apply**: when a review flags formatting, fix the named lines only; a repo-wide restyle is its own explicitly-scoped change.

- [ ] 🟡 **Design docs should brainstorm "what async work can settle while new UI is open"** → **Promote to schema** (superpowers-bridge design.md template / brainstorming checklist)
  > **Why**: D4 (bottom sheet) missed the armed-upload-gate × sheet-open race; it surfaced only at implementation review and cost a fix round (9f808c3).
  > **How to apply**: when a design introduces any modal/intermediate UI state over a page with background work (conversions, uploads, gates), add an explicit design question: what happens if pending async work settles while the modal is up?

- [ ] 📌 **Pay doc-of-contract findings immediately; don't defer them as minors** → **Promote to skill** (task-reviewer/subagent-driven-development fix-loop policy)
  > **Why**: the stale `ImageProcessor.process` doc deferred at Task 1 survived to the final review, which mandated it anyway — two review passes for one line.
  > **How to apply**: reviewers/classifiers should treat a doc comment that states a now-false contract on a changed seam as Important, not Minor.

- [ ] 📌 **Test-infra: concurrent `flutter test` files share systemTemp while `capture_session_test.dart` sweeps every `mmcpic-session-*` dir** → **One-off** (follow-up task on the repo, not this change)
  > **Why**: a corpus-wide flake source, pre-dating this change; this branch scoped its own witnesses around it (corpus-unique order numbers, difference-based dir checks) but other suites remain exposed.
  > **How to apply**: if an unexplained suite failure shows a missing `mmcpic-session-*` dir, suspect the sweep race; fix by scoping the sweep to its own corpus-unique prefix.

*(Unchecked items carry into the next cycle's retro for re-evaluation per the carry-forward mechanism.)*
