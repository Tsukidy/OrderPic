<!--
Raw capture of superpowers:brainstorming output.

This file is the live capture of the brainstorming session held
2026-09-18 with the operator (decision log: background → clarifying
questions → approved design). It REPLACES an earlier draft that had been
assembled from a prior session's memory notes — the operator clarified
that session's outcome was never their approval, so the design below was
re-derived and approved in this session. design.md reorganizes this
content into structured sections; the two are complementary, not
overlapping.
-->

# Brainstorm — write-through capture & upload prefs (settings-save-change)

## Background

The Settings page (`lib/settings/settings_page.dart`) edits the whole
`AppSettings` umbrella in two sections — "Capture & upload" on top, "SMB
connection" below — with purely local edit state: five connection
`TextEditingController`s plus `_folders` / `_batch` / `_format` /
`_quality` / `_customQuality` / `_customMaxEdge`. Nothing persists until
the Save button (same row as "Test connection") is pressed; back
discards everything, capture prefs included.

The operator's complaint: flip the format segment, press back, and the
choice is silently gone. Discard-without-save should be a deliberate,
connection-only behavior — a half-entered credential set is exactly what
should NOT persist — not a side effect of toggling a checkbox. This
matches how Android preference screens normally behave.

## Clarifying questions and answers (operator-decided)

**Q1 — When a capture/upload preference changes, when is it written to
the encrypted store?**
→ **Immediately on change** (write-through). Each change is persisted
the moment it is made; back needs no save step, and a mid-edit process
kill can't lose anything. (The alternative — persist everything when
leaving the page — also satisfies "not undone on back" but loses the
last edits if the OS kills the process first; rejected by the operator.)

**Q2 — If the store write fails (e.g. keystore error), what happens to
the control that was just toggled?**
→ **Revert + snackbar.** The control visibly reverts, the shared
notifier is never updated, and the existing "Could not save settings"
snackbar explains why — what the app uses and what is persisted can
never diverge. (Rejected: keep it applied for the session with a
warning — UI and store would disagree until the next successful write.)

**Q3 — The custom max-long-edge field is free text; when does what was
typed persist?**
→ **On edit complete** — focus leaves the field or the keyboard's Done
is pressed — and any un-persisted text is flushed when the page closes,
so back can't drop it. Matches the slider's precedent (persists on
release, not per drag tick); avoids storing absurd intermediate values
(e.g. a 2px cap while typing "2048"). (Rejected: persist per valid
keystroke — stores partial values and writes the store several times per
number.)

## Design presented and approved

- Prefs controls stop keeping their own state copies and read from the
  shared `ValueNotifier<AppSettings>`; a change builds the new
  `UploadPrefs`, persists through the `SettingsStore` seam, and only on
  success updates the notifier — the revert-on-failure behavior falls
  out for free because the control never moved.
- Persist timing: toggles and segments on tap; slider thumb moves freely
  with a live label but persists on `onChangeEnd`; the max-edge field on
  edit complete plus a flush on page close. Writes serialize through a
  queue so quick successive changes can't lose an update.
- SMB connection section unchanged in spirit: Save persists the
  CONNECTION only (validation, Test connection, pop unchanged; back
  still discards connection edits in gear mode; first-run gate
  untouched, and the prefs controls visible there write through like
  anywhere else).
- Instance discipline preserved: unchanged form values reuse the live
  `ConnectionSettings` instance and prefs writes never construct a
  connection, so History's `ObjectKey(settings.connection)` never
  remounts on a pref change.

The operator approved this design ("Yes you can proceed").

## Trade-offs weighed

- **Status quo (explicit Save for everything)**: rejected — silent data
  loss on back for prefs; contradicts Android conventions.
- **Persist-on-back (write all prefs when the page closes)**: rejected —
  process death loses the last edits.
- **Write-through prefs + explicit connection form (chosen)**: matches
  Material prefs patterns; keeps the credential form's Save as its
  validation and first-run gate.
- **Optimistic UI flip, revert on failure**: rejected — flicker on
  failure plus revert plumbing; commit-after-write gives the same
  observable behavior with none of the machinery (at the cost of an
  imperceptible async gap before a toggle visibly settles).

## Scope

Files in scope: `lib/settings/settings_page.dart`,
`test/settings_page_test.dart`; delta on the `upload-settings`
capability spec ("Upload preferences persistence", "Upload preference
changes leave History alone"). The `smb-settings` spec's connection
semantics are untouched. Out of scope: the parallel `recent-scans`
change (separate worktree; scanner/homescreen only — no file overlap).
