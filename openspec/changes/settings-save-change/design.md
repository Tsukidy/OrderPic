# settings-save-change — design

## Context

`SettingsPage` (`lib/settings/settings_page.dart`) is one widget with two
entry modes — gear-invoked "Settings" (back discards) and first-run
"Set up SMB login" (back blocked until a valid save). It edits the whole
`AppSettings` umbrella in two sections, but everything is local edit
state until Save: five connection `TextEditingController`s plus
`_folders` / `_batch` / `_format` / `_quality` / `_customQuality` /
`_customMaxEdge`. `_save()` validates the form, persists the whole
`AppSettings`, applies the connection-instance discipline, and pops.

Surrounding invariants that shape the design:

- The shell holds a single `ValueNotifier<AppSettings>`; pages read
  `.value.upload` / `.value.connection` at operation time, so a
  mid-edit notifier update IS the live-apply mechanism — no new
  propagation channel needed.
- `HomePage` re-keys `HistoryPage` on `ObjectKey(settings.connection)`
  (`ObjectKey` compares with `identical()`); `AppSettings.copyWith`
  reuses untouched halves BY INSTANCE. A prefs write must never
  construct a connection, or History remounts spuriously.
- `ValueNotifier` suppresses notification when the new value is
  `==`-equal, so a write that produces an equal `AppSettings` rebuilds
  nothing.
- Persistence goes through the `SettingsStore` seam (`read`/`write`/
  `delete`) — widget tests inject `InMemorySettingsStore`, and a
  throwing fake can drive the failure path without platform channels.

Operator decisions from the brainstorm (see brainstorm.md): persist
immediately on change; on store-write failure revert the control +
existing snackbar; the free-text max-edge field persists on edit
complete (focus loss / Done) with a flush when the page closes.

## Goals / Non-Goals

**Goals:**

- Capture & upload prefs apply live and persist at the moment of change;
  back never silently discards them.
- Store-write failure leaves prefs (and the notifier) exactly as they
  were, with the existing snackbar as the only surface that says so.
- The SMB connection section keeps today's exact form semantics —
  validation, Test connection, Save-then-pop, back-discards in gear
  mode, first-run gate.
- History's remount/re-list behavior is observably unchanged: pref
  changes never remount or re-list it; unchanged connection saves never
  remount it.
- First-run mode gets the same write-through prefs with no change to the
  gate.

**Non-Goals:**

- No change to the connection form's interaction (no unsaved-changes
  warning, no autosave for credentials).
- No storage-key, schema, or migration changes — `UploadPrefs.save`
  keeps writing the same six `upload.*` keys.
- No new UI (no per-control "saving…" indicators, no confirmation
  dialogs).
- No touching `recent-scans` territory (scanner/home shell) — parallel
  change in its own worktree.

## Decisions

### D1: Write-through at the moment of change

- **Choice**: every prefs interaction persists immediately — toggles and
  both segmented buttons on tap; the custom quality slider on
  `onChangeEnd`; the max-edge field on edit complete plus a flush when
  the page closes.
- **Why**: the operator chose immediate persistence over
  persist-on-page-exit — a mid-edit process kill can't lose anything,
  and back needs no special casing. Per-control timing: tap controls
  have no intermediate state; the slider's drag ticks are meaningless
  individually (the in-repo precedent is `onChangeEnd`); a free-text
  field's natural commit point is finishing the edit.
- **Alternatives considered**: persist all prefs when the page closes —
  rejected (process death loses edits); persist the field per valid
  keystroke — rejected by the operator (stores partial values like a 2px
  cap mid-typing, several writes per number).

### D2: Controls read the notifier; commit only after the write succeeds

- **Choice**: the toggles/segments' displayed values come from
  `widget.settingsNotifier.value.upload` (no `_folders`/`_batch`/
  `_format`/`_quality` fields). A change handler builds the new
  `UploadPrefs` from the current notifier value, awaits the store write
  of that new value, and only then assigns
  `settingsNotifier.value = current.copyWith(upload: newUpload)`. On
  failure: do nothing but show the snackbar.
- **Why**: the revert-on-failure requirement falls out for free — the
  control never moved, because its value was never optimistically
  changed. "Applied live" and "persisted" can never diverge, and
  `ValueNotifier`'s `==` suppression means a no-op write rebuilds
  nothing.
- **Alternatives considered**: optimistic local flip + revert on
  failure — rejected (flicker on failure, extra revert plumbing, and the
  JPEG⇄PNG visibility flip would briefly lie); local mirror state
  synced to the notifier — rejected (two sources of truth, which is what
  this change removes).

### D3: The JPEG⇄PNG visibility flip follows the notifier

- **Choice**: the quality block's `if (_format == jpeg)` mounts test
  reads the notifier's format, so the quality controls disappear the
  moment the PNG write commits and stay if it failed. The block's
  "selection survives hide/show" property needs no hoisted state
  anymore — the notifier holds it.
- **Why**: one source of truth; the visibility flip inherits the same
  commit-after-write semantics as every other control.
- **Alternatives considered**: keeping visibility on local state —
  rejected (would let the UI show quality controls for a format the app
  isn't actually using).

### D4: Local state survives only where a gesture needs it

- **Choice**: exactly two pieces of local state remain: the slider's
  in-drag label value (`onChange` updates it so the "JPEG quality: N"
  text tracks the thumb; `onChangeEnd` persists + commits) and the
  max-edge `TextEditingController` (inherently local), whose commit
  fires on focus loss / field submit / page close.
- **Why**: gesture feedback is inherently transient; everything
  meaningful lives in the notifier.
- **Alternatives considered**: a `ValueListenableBuilder` around the
  slider label — rejected (the drag label updates faster than and
  independently of commits; coupling them would thrash).

### D5: One serialized persist-commit queue

- **Choice**: all prefs commits funnel through a single
  `_pending = _pending.then((_) => _commit(...))` chain; each commit
  snapshots the notifier value at its own turn, writes the new
  `UploadPrefs` through the store, then assigns the notifier.
- **Why**: two quick changes (or a field commit racing a tap) would
  otherwise interleave whole-object writes and could resurrect a stale
  key (lost update). Serialization makes last-tap-wins the actual
  semantics, and each commit's write is internally consistent.
- **Alternatives considered**: per-key writes only for the changed key —
  rejected (six-key writes are already what `UploadPrefs.save` does;
  changing the write granularity adds a second persistence shape for no
  measured gain); unserialized fire-and-forget writes — rejected (lost
  updates).

### D6: Save persists the connection only

- **Choice**: `_save()` keeps validation, builds `_formSettings()`, and
  calls `ConnectionSettings.save` (the five `smb.*` keys) instead of
  `AppSettings.save`; the instance discipline is unchanged (unchanged
  form values reuse the live instance); `pop(true)` stays. Upload prefs
  no longer ride Save in any form.
- **Why**: the operator's split — the credential form is the deliberate,
  validated, first-run-gating path; with prefs writing through, a
  whole-umbrella Save would only re-write values the page no longer
  owns.
- **Alternatives considered**: dropping the Save button entirely —
  rejected (first-run needs the gate, and credentials deserve an
  explicit commit); renaming the button — rejected (it still saves the
  thing it always meant to save).
- **Note**: `AppSettings.save` stays on the model (a legitimate umbrella
  persist, covered by model tests); the page just stops calling it.

### D7: Shell and first-run are untouched

- **Choice**: `HomePage` isn't modified — it already ignores the
  settings route result and re-keys History on connection identity only.
  First-run keeps `canPop: !firstRun` and the post-save pop; the prefs
  controls visible in first-run mode write through like anywhere else.
- **Why**: live-apply rides the existing notifier; the gate is about the
  connection only, and prefs need no save to stick there.
- **Alternatives considered**: pop-result signaling — rejected (nothing
  consumes it).

## Risks / Trade-offs

- [Trade-off] A toggle settles visually only after the store write
  (usually single-digit milliseconds on Android Keystore-backed
  storage) → Accepted: imperceptible on success, and on failure
  "never moved" IS the revert — no flicker, no revert plumbing.
- [Risk] Rapid successive changes interleave async writes → Mitigation:
  D5's serialized commit queue; each commit snapshots at its turn, so
  last-tap-wins is structural, not luck.
- [Risk] The max-edge field's flush-on-close must run before the
  controllers dispose, including programmatic pops (Save) and system
  back → Mitigation: hook the pop at the `PopScope` callback level (and
  the same commit path as focus loss/submit), so every exit flushes the
  same way; covered by a widget test.
- [Trade-off] A process kill mid-typing loses the half-typed edge cap →
  Accepted (operator chose edit-complete over per-keystroke); the
  flush-on-close narrows the window to "killed while the page is open
  with a dirty field".
- [Risk] Widget tests that used Save as the persist trigger all change →
  Mitigation: mechanical rewrite to write-through expectations plus new
  failure/revert coverage via a throwing `SettingsStore` fake — the seam
  already exists.
- [Trade-off] The snackbar text ("Could not save settings") predates the
  split and now fires for prefs writes but not connection saves →
  Accepted for this change (accurate in both contexts); rewording is a
  copy decision, not a contract.

## Migration Plan

N/A — no deployment, storage-key, or dependency changes; rollback is a
plain revert of `settings_page.dart` + its tests. Acceptance:
`flutter analyze` and `flutter test` green, plus a device pass — toggle
each control, leave via back and via Save, force-quit and relaunch to
confirm persistence; change a pref and confirm History doesn't
re-list/remount; edit connection fields and confirm back still
discards.

## Open Questions

None — the three forks (persist timing, failure behavior, field commit
point) were decided by the operator in the brainstorm; the remainder are
covered by D1–D7.
