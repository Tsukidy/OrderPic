# Retrospective: folder-bundling

> Written: 2026-09-11 (after verify passed)
> Commit range: `2bc512f..8a28eee`
> Worktree: `.claude/worktrees/folder-bundling` (branch `worktree-folder-bundling`, not yet merged)

---

## 0. Evidence

- **Commit range**: `2bc512f..8a28eee` (61 commits)
- **Diff size**: +8504 / −1456 lines across 41 files
- **Tasks done**: 33/33 (`grep -cE '^\s*- \[x\]' tasks.md`)
- **Active hours**: ~25 across five working sessions (planning + apply + four device re-passes)
- **Subagent dispatches**: 0 (single-operator flow; the operator IS the integration tester)
- **New external dependencies**: `flutter_image_compress ^2.5.1` (MIT) — lossless PNG conversion
- **Bugs encountered post-merge**: none (not yet merged; all findings landed pre-archive)
- **OpenSpec validate state at archive**: pass (3/3 items valid)
- **Test coverage signal**: 146/146 widget+unit tests (up from 20 at change start), `flutter analyze` clean

Commit chain (時序, summarized):

```
2bc512f refactor: split main.dart into lib/ modules (no behavior change)
15d4588 chore: rebrand app to OrderPic (new applicationId, orderpic package)
…        settings model + sectioned page (UploadPrefs/AppSettings, 2.x)
…        naming/session/processing (4-part names, CaptureSession, PNG, 3.x)
…        upload flow + batch UI (uploadSession, PreviewPage batch, 4.x)
…        history drill-down (folder tiles, OrderFilesPage, 5.x)
e9bc9e1 feat: fail-fast skipped shots + bounded auto-redial resume (6.9 — later superseded)
71265b9 feat: operator retry policy — in-place retry, rescue, partial cleanup (6.10)
1849127 fix: scanner can no longer scan under the capture flow (6.12)
4df2401 fix: recognize ghost-locked files (6.11)
be74125 fix: review-screen image centers in the visible band (6.13)
8a28eee chore: 6.13 closed — sighting was the system camera's own confirm screen
```

---

## 1. Wins

- [evidence: `test/uploader_test.dart`, `lib/capture/uploader.dart`] The 6.10 rewrite
  replaced the injected-writer seam with an injectable **connection factory**
  (`UploadConnection`), closing the gap 6.9 had shipped with a comment reading
  "real-path behavior is device-verified, not seam-tested" — the retry state
  machine (redial, ghost-lock, abort) is now fully unit-driven.
- [evidence: tasks.md 6.4–6.13] Every device-pass finding became an implemented,
  tested task row within hours of the operator reporting it — nine round trips
  from "user sees it" to "fixed + unit-verified", with the specs/design updated
  in the same commits rather than after.
- [evidence: design.md D9 addenda, spec rewrite] The SMB dead-session lock
  window (Windows holds a dead session's file handle ~1–2 min) was root-caused
  from the device log (`errno 103` + `StreamSink is closed` traces), written
  down, and the whole retry policy rebuilt around it instead of patching.
- [evidence: `test/camera_cancel_test.dart` covering-route test] The scanner
  under-capture bug was pinned to a specific package behavior
  (mobile_scanner 7.4.0 restarts its camera on EVERY app resume) by reading
  the installed package source, then fixed with a lookup-free `_covered` flag
  that `pushReplacement` (invisible to `RouteObserver`) cannot clear.
- [evidence: CLAUDE.md filename-contract section unchanged] The cross-feature
  filename contract survived contact with reality: capture-time 4-part names,
  dual-shape parsing, and History ordering all landed without a contract break.

---

## 2. Misses

- 🔴 [blocking | evidence: commit e9bc9e1's own doc comment, replaced by 71265b9]
  6.9 shipped the round-based auto-retry with its core path UNTESTABLE at the
  seam — the code said so out loud ("device-verified, not seam-tested") and
  shipped anyway. It raced a server lock window it could never win and burned
  the operator's re-pass. Cost: one full device cycle + a mid-verify redesign.
- 🟡 [painful | evidence: session log 2026-09-10] The agent ran
  `flutter analyze`/`flutter test` in the worktree WHILE the operator's
  `flutter run` device session was live — contending the build artifacts,
  muddying one finding, and getting cut off mid-verify. Now a memory rule
  (see §6) but shouldn't have needed the operator to enforce it.
- 🟡 [painful | evidence: this session's probe attempts] A from-scratch widget
  test ignored the file's own documented harness rules (real IO must go
  through `tester.runAsync` in FakeAsync) and hung for ~30 min across three
  attempts before the in-file harness was reused. The warning comment existed;
  it wasn't read.
- 📌 [nit | evidence: two exit-144 shell kills] `pkill -f <pattern>` matched
  the invoking shell's own command line and killed it — twice. Standard
  `'[f]oo'`-style self-exclusion was only adopted after the second self-kill.

---

## 3. Plan deviations

| Plan task | What changed | Why |
|-----------|--------------|-----|
| 2.5 / 4.2 / 4.4 | Folded into 2.2 / 4.1 / 4.3 | pure-logic vs UI split made separate rows redundant (pre-planned folds) |
| 6.1 (single device pass) | Became NINE re-passes (6.4–6.13) | every pass surfaced real findings the emulator/tests couldn't |
| 4.1 seam (`writeShot`/`ensureFolder`) | Replaced by the `dial`/`UploadConnection` factory in 6.10 | the injected-writer seam couldn't express redial/death; the 6.9 gap demanded a testable real path |
| batch-capture spec (twice) | Retry-semantics requirement rewritten in 6.10 (operator policy) and amended in 6.11 (ghost-lock) | device evidence contradicted both the original design and the first fix |
| uploader public API | `maxAutoRetries`/`retryDelays` removed, `retryWriteTimeout`/`redialDelay`/`dialTimeout` added | policy replaced round machinery; page-level injection (`PreviewPage.uploader`) kept the widget tests untouched |

---

## 4. Skill / workflow compliance

| Skill                                            | Used |
|--------------------------------------------------|------|
| superpowers:brainstorming                        | ✓ (pre-change; brainstorm.md Q1–Q8 fed design D1–D11) |
| superpowers:writing-plans                        | ✓ (plan.md, self-reviewed, 21 tasks → 33 with device findings) |
| superpowers:using-git-worktrees                  | ✓ (`.claude/worktrees/folder-bundling`, 61 commits isolated) |
| superpowers:subagent-driven-development          | ✗ (see below) |
| (transitive) superpowers:test-driven-development | ✓ (every fix this cycle: RED observed, then GREEN — uploader ×3, scanner guard, band centering) |
| (transitive) superpowers:requesting-code-review  | ✗ (see below) |
| superpowers:finishing-a-development-branch       | pending (merge happens at archive, immediately after this retro) |

### Deliberately Skipped Skills

- **superpowers:subagent-driven-development**
  - **What was skipped**: dispatching implementation to subagents per plan task
  - **Why this cycle**: single-operator, device-in-the-loop flow — tasks were
    verified by `flutter run` on the operator's physical device between ticks
    (commits 6dbf925, 40c528e interleave operator findings with ticks); a
    subagent can't hold the device token, and the work was executed in the
    operator's session rather than dispatched
  - **How to prevent recurrence**: `scope-judgment rule` — when the plan's
    verify step requires the operator's physical device, allow executing-plans
    in-session as the plan header's alternative already does (it lists both);
    no schema change needed, just record which was chosen
- **superpowers:requesting-code-review**
  - **What was skipped**: an adversarial review pass over the branch before verify
  - **Why this cycle**: the operator's device passes served as the acceptance
    review (nine findings = nine reviews), and the verify artifact re-checked
    specs/design/tasks coherence; but no INDEPENDENT code reviewer looked at
    the 8.5k-line diff
  - **How to prevent recurrence**: `CLAUDE.md trigger` — add to the bridge's
    apply guidance: "before `/opsx:verify`, run a code-review pass over
    `main..HEAD` (subagent OK — it reads code, not devices)"

---

## 5. Surprises

- Windows SMB doesn't REFUSE a create against a dead session's held file — it
  BLOCKS it. The "fast sharing violation" mental model (and the first fix's)
  was wrong; the only reliable signal is "dial succeeded, write stalled again".
- `mobile_scanner`'s widget restarts its camera on every `AppLifecycleState.resumed` —
  including the resume from the system camera mid-capture-flow, re-arming QR
  scanning under the covered route. Package-level lifecycle handling is not
  route-aware by default.
- `RouteObserver` has no `didReplace` — `pushReplacement` (used between all
  capture stages) is invisible to `RouteAware` subscribers. Coverage tracking
  must ride the one real push that starts the flow.
- `Future.timeout` drops late-arriving source errors into the zone as unhandled
  exceptions — the device-log `StreamSink is closed` spam was our own abandoned
  futures, not smb_connect misbehaving.
- The final "bug" of the cycle (landscape shots "at the top") was Google
  Camera's own confirm screen — not app-rendered at all. The app-side band
  centering it triggered is still a real improvement.

---

## 6. Promote candidates → long-term learning

- [x] 🔴 **Never run flutter tooling in the worktree during the operator's device session** → **Promoted to memory** (`no-flutter-commands-during-device-pass.md`)
  > **Why**: a background `flutter test` contended with the operator's live `flutter run` on 2026-09-10, muddying a finding and forcing the operator to cut the agent off mid-verify
  > **How to apply**: before ANY `flutter test`/`analyze`/`build`/`run`, check whether the operator's device session is live; when in doubt, ask

- [ ] 🔴 **A seam comment saying "X is device-verified, not seam-tested" is a ship-blocker, not a note** → **Promote to project CLAUDE.md**
  > **Why**: 6.9 shipped exactly that comment and its untested path failed on the first real network blip, costing a full device cycle and a mid-verify redesign (e9bc9e1 → 71265b9)
  > **How to apply**: during `/opsx:apply` ticks, treat such a comment in a diff as a RED — redesign the seam before ticking; add one line to CLAUDE.md's workflow section saying so

- [ ] 🟡 **Windows SMB holds a dead session's file handle ~1–2 min; creates BLOCK, deletes refuse, nothing client-side releases it early** → **Promote to project CLAUDE.md** (partially there via the SMB bullet; promote the full mechanics)
  > **Why**: cost two design iterations (6.9, 6.10) because the failure mode was assumed to be a fast refusal
  > **How to apply**: any future SMB write/retry work starts from design.md D9's addenda; don't re-derive

- [ ] 📌 **Reuse the file-local test harness; its comments encode paid-for lessons** → **Promote to memory**
  > **Why**: a fresh probe test ignored `preview_page_test.dart`'s documented FakeAsync/IO rules and hung ~30 min; the same file's comment says "learned the hard way"
  > **How to apply**: before writing any test in an existing suite, read that suite's helper section first

- [ ] 📌 **`pkill -f` matches your own shell's command line — use `[x]`-style self-exclusion** → one-off (generic shell hygiene, not project-specific)
