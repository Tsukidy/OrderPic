# Retrospective: ordernumber-entry

> Written: 2026-09-04 (after verify passed — PASS WITH WARNINGS)
> Commit range: `c7d128e..56c29bc`
> Worktree: `.claude/worktrees/ordernumber-entry` (branch `worktree-ordernumber-entry`)

---

## 0. Evidence

- **Commit range**: `c7d128e..56c29bc` (7 commits; archive commit follows this report)
- **Diff size**: +285 / −28 across 4 files — feature code itself is
  `lib/main.dart` (~+100/−17); the rest is OpenSpec artifacts
  (plan amendment, task ticks, verify.md)
- **Tasks done**: 7/7 (`grep -c '^- \[x\]' tasks.md` → 7)
- **Active hours**: ~2 (2026-09-04, single session; includes a user-run
  on-device acceptance pass)
- **Subagent dispatches**: 9 (3 implementers, 3 task reviewers, 1 final
  whole-branch reviewer, 1 fix-round resume, 1 scoped re-review)
- **New external dependencies**: none (Flutter SDK widgets/input formatters only)
- **Bugs encountered post-merge**: none merged yet; **1 bug found during the
  device acceptance pass and fixed pre-archive** — entry-dialog
  TextEditingController disposed during route exit animation (`fa0ad8b`)
- **OpenSpec validate state at archive**: pass for this change (pre-existing
  sibling stub `smb-path-settings-menu` fails validation — unrelated)
- **Test coverage signal**: n/a per repo stance (widget test is a deliberate
  placeholder); gate = `flutter analyze` clean + placeholder suite passing

Commit chain:

```
c7d128e chore: initial project baseline (repo had zero commits)
1a10bfa feat: manual order-number entry as fallback on Scan screen
ee3f1f0 refactor: QR path shares _startCapture with manual entry
fcf502b chore: tick completed ordernumber-entry tasks (device pass pending)
fa0ad8b fix: entry dialog controller disposed during route exit animation
42f26d6 docs: amend plan Step 3 — controller hoisted to State field
189223b chore: complete device acceptance pass — tick 2.2 and 3.2
56c29bc docs: verify report for ordernumber-entry (PASS WITH WARNINGS)
```

---

## 1. Wins

- [evidence: user acceptance + clean run log] The device pass caught a real
  crash that `flutter analyze`, three per-task reviews, and a final
  whole-branch review (Ready to merge: Yes) all missed — the repo's
  manual-on-device verification stance paid for itself this cycle.
- [evidence: `ee3f1f0` + re-review vs mobile_scanner 7.4.0 source] The
  `_startCapture` extraction made the QR path provably behavior-identical
  (the double-`stop()` was verified as a guarded no-op against the installed
  plugin source, not assumed).
- [evidence: `fa0ad8b`] The SDD fix loop worked as designed: root cause
  established from framework source (`navigator.dart:433–480` — "routes
  should not wait for their exit animation") before any fix; one round,
  user-remediation choice documented, scoped re-review clean, device
  re-verified.
- [evidence: diff — 4 files, `_ScannerPageState` only] Scope discipline held:
  no changes to `CameraPage`/`PreviewPage`/`HistoryPage`/SMB constants/
  filename contract.
- [evidence: ledger `.superpowers/sdd/plan/progress.md`] Ledger + review
  packages kept the whole multi-agent trail auditable; every tick maps to a
  review verdict.

## 2. Misses

- 🟡 [painful | evidence: `fa0ad8b`, run-log exception] The plan's authored
  dialog code shipped a dispose race: `showDialog`'s future completes at
  `Route.didPop`, before the exit animation, so `controller.dispose()` ran
  under a still-mounted TextField and crashed on first real use. Found by
  the user on hardware, not by any review tier.
- 📌 [nit | evidence: background tasks `b8nm9i77n` → `bzed6p2nt`] `flutter
  run` in a background (no-stdin) session cannot hot-reload; each fix
  iteration needed a full restart of the run session.
- 📌 [nit | evidence: run log, Android 17 device] `image_picker` emits
  "Implicit URI read grant … discontinued from Android 18" deprecation
  warnings — plugin-level, pre-existing, out of this change's scope; will
  need a plugin upgrade before Android 18.
- 📌 [nit | evidence: verify.md §1] Sibling stub change
  `smb-path-settings-menu` (only a `.openspec.yaml`) fails `openspec
  validate --all` — pre-existing clutter from the baseline commit.

## 3. Plan deviations

| Plan task | What changed | Why |
|-----------|--------------|-----|
| Task 1 Step 3 (dialog code) | local `TextEditingController` disposed after `showDialog` → controller hoisted to a `_ScannerPageState` field (`fa0ad8b`), plan.md amended (`42f26d6`) | framework completes the dialog future before the route's exit animation; original code crashed on device |
| Task 1 Step 6 / Task 2 Step 3 (on-device checks) | not run at implementer time; executed later as a user-driven device pass | no Android device attached to the build machine during those tasks; user attached a Pixel 9 Pro XL afterward |
| Task 3 Step 3 (tick + commit) | ticked in two batches with adjusted commit messages (`fcf502b`, `189223b`) | device pass was split across the session; messages reflect actual state |
| Tasks.md 1.1 wording | "semi-transparent bar" vs shipped `FilledButton.tonalIcon` | the plan's own authored code; wording nit recorded, not changed |

## 4. Skill / workflow compliance

| Skill                                            | Used |
|--------------------------------------------------|------|
| superpowers:brainstorming                        | ✓ (pre-apply; brainstorm.md exists) |
| superpowers:writing-plans                        | ✓ (plan.md existed) |
| superpowers:using-git-worktrees                  | ✓ (native EnterWorktree; required a user-approved baseline commit first — repo had zero commits) |
| superpowers:subagent-driven-development          | ✓ (9 dispatches, ledger, fix loop) |
| (transitive) superpowers:test-driven-development | ✗ (see below) |
| (transitive) superpowers:requesting-code-review  | ✓ (3 task reviews + final whole-branch review + 1 scoped re-review) |
| superpowers:finishing-a-development-branch       | ⏳ runs after archive, per opsx ordering |

### Deliberately Skipped Skills

- **superpowers:test-driven-development**
  - **What was skipped**: the test-first (RED-GREEN-REFACTOR) mandate for
    every implementer task; verification was `flutter analyze` + the
    existing placeholder suite instead.
  - **Why this cycle**: plan.md Global Constraints line 18 — "no new tests —
    `test/widget_test.dart` is a deliberate placeholder (main flow needs
    camera + SMB hardware)" — and CLAUDE.md's testing stance say the same.
    The skipped skill's requirement is overridden by explicit project
    instructions, which take precedence per `using-superpowers`. Not a
    cycle-condition escape hatch; a documented project-level policy.
  - **How to prevent recurrence**: `scope-judgment rule` — when a repo's
    CLAUDE.md documents a hardware-gated testing stance and the approved
    plan encodes "no new tests", SDD dispatches should state that
    resolution explicitly (done here) and TDD is satisfied vacuously; no
    schema or skill change needed. Revisit only if the repo ever adds a
    hardware-free test harness.

## 5. Surprises

- `showDialog`'s returned future completes **before** the dialog's exit
  animation runs (`Route.didPop` → `didComplete` completes it immediately;
  framework docs state routes "should not wait for their exit animation").
  Two review tiers (task reviewer + final opus reviewer) examined controller
  disposal timing and cleared it — the checked path (`removeListener` after
  dispose is safe) was not the path that fired (`addListener` after dispose).
- The repo had no initial commit, so no worktree could exist until one was
  made — resolved by a user decision (baseline commit, then worktree).
- The double-pop dialog footgun the final review flagged as Minor exists
  identically in the pre-existing QR dialog and has never bitten in
  production use — latent, not new.

## 6. Promote candidates → long-term learning

- [ ] 🟡 **Never dispose a dialog-local TextEditingController on the
  `showDialog` future** → **Promote to memory** (type: feedback)
  > **Why**: `Route.didPop` completes that future before the exit
  > animation, so dispose runs under a still-mounted TextField and crashes
  > on device (`fa0ad8b`); analyzer and two review tiers missed it.
  > **How to apply**: any Flutter dialog holding a TextEditingController —
  > hoist the controller to the enclosing State (dispose in `dispose()`,
  > clear on open) instead of disposing after `await showDialog`.

- [ ] 🟡 **A clean review stack does not substitute for the on-device
  pass** → **Promote to project CLAUDE.md** (testing stance section)
  > **Why**: analyze + 3 task reviews + final whole-branch review all
  > passed code that crashed on the first real tap; only hardware
  > reproduced the route-animation race.
  > **How to apply**: keep the manual device pass mandatory for any change
  > touching dialog/route/camera flow, even when every automated gate and
  > review is green.

- [ ] 📌 **`flutter run` in a background session can't hot-reload (no
  stdin)** → **Promote to memory** (type: project)
  > **Why**: iteration on a connected device required killing and
  > relaunching the run session for every code change.
  > **How to apply**: when driving an attached device from Claude Code,
  > budget for full `flutter run` restarts, or run an interactive session
  > the user drives for hot-reload loops.

- [ ] 📌 **A zero-commit repo blocks the worktree-first workflow** →
  **One-off**
  > **Why**: unique to this repo's first cycle (baseline commit now
  > exists); does not generalize.
