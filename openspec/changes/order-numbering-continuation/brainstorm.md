<!--
Raw capture of superpowers:brainstorming output.

Live capture of the brainstorming session held 2026-09-18 with the
operator (decision log: background → clarifying questions → approved
design). The operator approved the design at the end of the session.
design.md reorganizes this content into structured sections; the two are
complementary, not overlapping.
-->

# Brainstorm — cross-session shot-index continuation (order-numbering-continuation)

## Background

Upload filenames are `{OrderNumber}_{YYYYMMDD}_{HHMMSS}_{NNN}.ext`,
stamped at capture time (`lib/capture/naming.dart`
`buildUploadFileName`). `NNN` comes from `CaptureSession.nextIndex` =
`_shots.length + 1` (`lib/capture/session.dart`) — a purely in-session
counter. A second capture pass for an order that already has
`…_001`–`…_003` on the share therefore starts over at `…_001`. (No
overwrites — the timestamp differs — but the numbering restarts, which
is the defect the operator reported.) The fix: the counter should seed
itself from the files already in the destination folder.

Mechanics that shape the design:

- The destination folder depends on a pref: `sharePath/<order>/` when
  per-order folders are on, `sharePath/` (filter by the `{order}_`
  prefix) in flat mode (`uploadTargetPath`, `lib/capture/uploader.dart`).
- The SMB side already has the listing pattern (History's `conn.file` +
  `listFiles`), and the repo has an injectable-seam style
  (`SettingsStore`, `ImageProcessor`, `dial`) for SMB-free tests.
- Contract guard: `parseUploadName` accepts EXACTLY 3-digit indexes
  (`naming.dart`) — relevant once an order crosses `_999`.
- `scanner_page._startCapture` creates the session; `camera_page` is the
  admission driver. `session.dart` is deliberately pure-dart (no SMB
  imports) and is tested without fakes.

## Clarifying questions and answers (operator-decided)

**Q1 — Where should the continuation be computed?**
→ **Seed at session start.** When the session is created, an SMB
listing of the destination folder runs in the background (concurrent
with the camera/picker being open); the first shot's admission awaits
it — normally already resolved by the time a shot exists. Names stay
stamped-at-capture: preview/review/History all see the final names.
Costs one extra SMB connection per session. (Rejected: re-stamp at
upload — breaks the stamped-at-capture contract; the review-time name
could differ from the uploaded name and the retry machinery keys on
`shot.fileName`. Rejected: list before every shot — N round-trips and
admissions serialize behind the network.)

**Q2 — The seed listing can fail (share offline, slow LAN, timeout).
What then?**
→ **Silent fallback to seed 1** — exactly today's behavior. The
listing never blocks or fails the capture; the staging path stays
pure-local and instant. Also covers the unconfigured-username case (the
`connect` guard refuses to dial). If the share comes back before
upload, that one session's names simply aren't continued.

**Q3 — An order can accumulate more than 999 shots over time. What
happens past `_999`?**
→ **Let it grow and relax the parser.** `padLeft(3)` already produces
`_1000`, `_1001`… naturally; `parseUploadName` relaxes from "exactly 3
digits" to "3 or more digits" (backward compatible; the legacy 3-part
shape stays accepted; History keeps parsing). Known cosmetic: string
sort places `_1000` before `_999` for orders with 1000+ shots —
documented and accepted. (Rejected: clamp at `_999` — numbering stops
meaning anything past 999.)

## Design presented and approved

- **The seed.** A new injectable resolver (house seam pattern) does one
  SMB job: list the session's destination folder — `sharePath/<order>/`
  with folders on, `sharePath/` filtered by the `{order}_` prefix in
  flat mode — and return max(parsed NNN) + 1 over names that parse as
  the current 4-part shape with a MATCHING order number. Legacy 3-part
  names carry no index and are ignored; unparseable files are ignored.
  Fresh order or nothing usable → seed 1 (today's behavior).
- **Session offset.** `CaptureSession` gains `baseIndex` (default 1);
  `nextIndex` = `baseIndex + _shots.length`. Everything in-session —
  removed-middle index reuse, `claimsFile`, batch admission order —
  works unchanged, just offset. SMB stays out of `session.dart`: the
  seed is attached from outside (the admission path awaits the seed
  future at the FIRST admission only; later admissions never wait).
- **Timing.** `_startCapture` kicks the listing off at session
  creation; it runs while the camera/picker is open. Failure (offline,
  timeout, unconfigured, throw) → silent seed 1. One extra SMB
  connection per session, closed in a `finally`.
- **Parser relax.** "Exactly 3 digits" → "3 or more digits" in
  `parseUploadName`, with a pure `seedFromNames(names, order)` helper
  beside it.

The operator approved this design ("Yes that appears correct proceed").

## Trade-offs weighed

- **Seed at session start vs re-stamp at upload**: re-stamping would
  avoid the extra connection but breaks stamped-at-capture (review
  shows one name, the share gets another; retry keys on
  `shot.fileName`). Seed-at-start keeps every name final from the
  moment it exists.
- **Seed at session start vs list-per-shot**: per-shot listing is the
  most "current" but serializes admissions behind N network calls and
  slows the multi-pick path.
- **Silent fallback vs guaranteed continuation**: guaranteeing the
  seed (retry-until-answer) would hang or fail capture when the
  network is down — against the app's fail-soft capture philosophy.
- **Grow past `_999` vs clamp**: clamping keeps the name shape stable
  but makes the index meaningless past 999; the parser relax is a
  small, backward-compatible contract change.

## Scope

Files in scope: `lib/capture/naming.dart` (parser relax + pure
`seedFromNames`), `lib/capture/session.dart` (`baseIndex`/attach —
still SMB-free), a new small seed-resolver file (SMB listing; beside
`lib/smb/smb.dart`'s orbit), `lib/pages/scanner_page.dart` (kickoff at
session creation — one call), `lib/pages/camera_page.dart`
(await-at-first-admission); tests: `test/naming_test.dart`,
`test/capture_session_test.dart`, a resolver test with a scripted
`listDir` fake, and the admission-flow widget tests.

Spec home: the `photo-naming` capability (the filename contract and
parser shape are its spec'd surface).

Coordination note: `scanner_page.dart` is in the parallel
`recent-scans` change's territory (own worktree, scanner/homescreen);
the kickoff is a single call at session creation, so the merge surface
is small but real.
