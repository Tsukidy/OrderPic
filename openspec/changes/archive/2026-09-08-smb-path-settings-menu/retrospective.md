# Retrospective: smb-path-settings-menu

> Written: 2026-09-08 (after verify passed — PASS WITH WARNINGS)
> Commit range: `fb77eea..641a8a7`
> Worktree: `.claude/worktrees/smb-path-settings-menu` (branch `worktree-smb-path-settings-menu`)

---

## 0. Evidence

- **Commit range**: `fb77eea..641a8a7` (13 commits)
- **Diff size**: +3056 / −52 lines across 21 files
- **Tasks done**: 22/23 (`grep -cE '^\s*- \[x\]' tasks.md` → 22; 6.4 device pass partially exercised — see verify.md §2)
- **Active hours**: ~3 sessions, 2026-09-04 (planning: brainstorm→plan), 2026-09-04/05 (implementation: 9 tasks + reviews + fix waves), 2026-09-08 (device pass, bug triage, verify)
- **Subagent dispatches**: 23 subagents, 26 dispatches (3 fix-round resumes of live implementers)
- **New external dependencies**: `flutter_secure_storage` 11.0.0 (MIT) — required `compileSdk` 37
- **Bugs encountered post-merge**: 0 merged; 1 device-pass report ("History not showing new image") triaged to pre-existing pull-to-refresh-per-mount behavior, not a regression
- **OpenSpec validate state at archive**: pass (2/2 items valid; 1 out-of-scope WARNING on `manual-order-entry` Purpose placeholder)
- **Test coverage signal**: 20/20 Flutter tests green (8 model/persistence unit, 9 SettingsPage widget, 2 HomePage gate widget, 1 placeholder); `flutter analyze` clean

Commit chain:

```
2de6c67 docs: smb-path-settings-menu planning artifacts (brainstorm through plan)
6f96a01 feat: SmbSettings value class replaces hardcoded SMB constants
b9230c5 feat: encrypted SMB settings persistence with injectable store seam
3ace1a2 refactor: shared connect() helper with unconfigured guard
fe8988d feat: SettingsPage form with validation and obscured password
02ff62b feat: settings test-connection and save with first-run mode  (fix: Save disabled while testing)
bb1a23c feat: wire settings through the app shell with first-run gate
de8d642 chore: disable Android backup for credential data
25cc4b4 chore: bump compileSdk to 37 for flutter_secure_storage 11
1d2104b docs: CLAUDE.md SMB layer reflects settings menu
1a8dc29 test: dedicated empty-host validation case
aa13064 chore: tick 7.2 — ordernumber-entry merge resolved by base
641a8a7 fix: final-review wave — gate autofocus, test-result hygiene, docs/tests polish
```

---

## 1. Wins

- [evidence: plugin source check in final review] The security goal is real, not cosmetic: credentials absent from binary, Keystore-encrypted at rest (reviewer verified `flutter_secure_storage` 11's AES-GCM defaults), backup-disabled, wipe-on-corrupt recovery — old `opk` pair exists nowhere in the tree or tests.
- [evidence: commit chain, per-task reviews] Verbatim-code TDD plan made implementation nearly transcription-grade: every task's diff was brief-faithful, RED→GREEN evidence captured, and all reviews came back clean or with adjudicated deviations.
- [evidence: test count 0 → 20] The `SettingsStore` seam (design D2) is what made the repo's first unit/widget tests possible — the highest-leverage design decision in the change.
- [evidence: fix rounds 02ff62b, 25cc4b4, 641a8a7] The review loop earned its cost: it caught a spec-MUST omission (gate autofocus — missed by three per-task reviews, caught by the final whole-branch reviewer), a plan-code/constraint contradiction (Save during test), a wrong-share upload bug (plan gap in `_upload` sharePath), and a build-breaking compileSdk requirement.
- [evidence: device session 2026-09-08] First hardware run of the gate worked: setup appeared, saved, upload landed on the real share, History displayed it — no on-device defects in new code.

## 2. Misses

- 🟡 [painful | evidence: 641a8a7 vs spec Req 3] Plan's own code snippets contradicted or omitted its constraint text in 4 places (autofocus, Save-during-test, `_upload` sharePath, unperformable manual step 7). All caught by reviews — but the plan self-review pass checked placeholders/consistency, not snippet-vs-MUST compliance.
- 🟡 [painful | evidence: 25cc4b4] `flutter pub add` in Task 2 silently required compileSdk 37; discovered only when Task 7 ran the first APK build. A build immediately after adding a native-plugin dependency would have surfaced it 5 tasks earlier.
- 📌 [nit | evidence: device triage 2026-09-08] History's per-session-mount listing (pull-to-refresh to see new uploads) confused a real user mid-pass and cost a debugging round — pre-existing behavior, but undocumented.
- 📌 [nit | evidence: verify.md §2] 6.4 left partially ticked at verify time (primary flow done; restart/repoint/clear-data sub-checks pending owner confirmation).

## 3. Plan deviations

| Plan task | What changed | Why |
|---|---|---|
| 7 | + `compileSdk` 36→37 commit | flutter_secure_storage 11 platform floor; plan's Task-2 note anticipated an Android setup step |
| 6 | `_upload` also snapshots `sharePath` for createFolder/createFile | Plan gap — defaults-target would upload to wrong share after repointing; caught by implementer |
| 9 | Collapsed to verification-only | `ordernumber-entry` had already merged+archived into the branch base; no conflict existed |
| 4 | Toggle test asserts via descendant `TextField` | `TextFormField.obscureText` getter doesn't exist on Flutter 3.47.1 |
| 5 | `onPressed: _testing ? null : _save` | Plan's constraint text mandated both-buttons-disabled; its snippet didn't |
| 8 | + dedicated empty-host test; manual step 7 reworded | Make 6.1's tick literally accurate; step was unperformable as written |
| 5 (back-blocked test) | `handlePopRoute()` instead of `pageBack()` | Findings 4+5 mutually exclusive as written (hidden arrow breaks pageBack) |

## 4. Skill / workflow compliance

| Skill                                            | Used |
|--------------------------------------------------|------|
| superpowers:brainstorming                        | ✓ (with opsx output redirection; 2 review-time reversals Q6/Q7) |
| superpowers:writing-plans                        | ✓ (self-review pass; 4 snippet bugs still slipped — see §6) |
| superpowers:using-git-worktrees                  | ✓ (native EnterWorktree; artifacts copied in + committed) |
| superpowers:subagent-driven-development          | ✓ (23 subagents, ledger-tracked, 2 fix loops + 1 authorized scope addition) |
| (transitive) superpowers:test-driven-development | ✓ (every task RED→GREEN with captured evidence) |
| (transitive) superpowers:requesting-code-review  | ✓ (per-task reviews + final whole-branch opus review) |
| superpowers:finishing-a-development-branch       | pending — schema sequences it after archive (step 6), not skipped |

### Deliberately Skipped Skills

(none — all ✓ or schema-sequenced pending)

## 5. Surprises

- `ordernumber-entry` completed, verified, and archived onto `main` while we planned — our branch was created after it landed, evaporating the anticipated merge conflict (Task 9).
- `TextFormField` exposes `obscureText` as constructor-only on Flutter 3.47.1 — plan-authored widget tests couldn't compile as written.
- flutter_secure_storage 11 demands compileSdk 37 while AGP 9.1.0's recommended maximum is 36 — green build sits above AGP's recommendation until the next toolchain bump.
- Session-shell PATH doesn't see mid-session SDK installs (adb) — absolute path worked around it.
- A human tester instinctively ran the main checkout, not the worktree — worktree isolation confuses people, not just tools; "which tree am I running" needs to be explicit during device passes.

## 6. Promote candidates → long-term learning

- [ ] 🟡 **Re-check plan code snippets against constraint text and spec MUSTs before apply, not just for placeholders** → **Promote to memory** (type: feedback)
  > **Why**: Four snippet-level defects (autofocus, Save-during-test, upload sharePath, unperformable manual step) survived plan self-review and were only caught by downstream reviewers — one spec MUST reached verify-time unticked-accurate only via the final review.
  > **How to apply**: When finishing any writing-plans artifact, diff each code snippet against the Global Constraints and the spec's MUST/scenario lines before invoking apply.

- [ ] 🟡 **Run a real build immediately after adding any native-plugin dependency** → **Promote to memory** (type: feedback)
  > **Why**: `flutter pub add flutter_secure_storage` (Task 2) silently required compileSdk 37; the branch was un-buildable for 5 tasks until Task 7's first APK attempt (25cc4b4).
  > **How to apply**: In any Flutter plan, the task that adds a platform-integrating dependency must end with `flutter build apk --debug`, not just `pub get` + analyze.

- [ ] 📌 **History lists once per mount — document the pull-to-refresh expectation** → **Promote to project CLAUDE.md** (History/UX note in "Architecture → Navigation model")
  > **Why**: A real device-pass user read the stale list as "History broken" and filed it as a bug; the behavior is pre-existing and by design.
  > **How to apply**: Whenever documenting or changing the History tab, state that revisit ≠ re-list and pull-to-refresh (or a settings change) re-lists.

- [ ] 🟡 **Rotate the SMB password before calling rollout done** → **One-off** (owner action; surfaced by final review)
  > **Why**: The old credential pair remains in git history (`fb77eea` and earlier) and every previously built APK — the exposure this change was built to remove.
  > **How to apply**: At rollout, change the SMB account password; the app's new first-run/settings flow makes that self-service.

- [ ] 📌 **Fill `manual-order-entry` spec's placeholder Purpose** → **One-off** (next housekeeping pass)
  > **Why**: `openspec validate` flags it every cycle; it's an `ordernumber-entry` archive leftover, not this change's defect.
  > **How to apply**: One-line edit to `openspec/specs/manual-order-entry/spec.md` `## Purpose`.

- [ ] 📌 **Inject `connect` at page boundaries to make SMB dialing widget-testable** → **One-off** (future change candidate)
  > **Why**: Live Test connection and on-device repoint auto-refresh are the two true manual-only gaps (verify.md §7); a seam would close both.
  > **How to apply**: If SMB flow regressions ever appear, propose the seam as its own small opsx change rather than bolting it on.
