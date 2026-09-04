# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MMCPic (`mmcpicv4`) — a Flutter app, Android-primary, for a photo-capture workflow: scan a QR-coded order number, photograph the item with the system camera app, review the shot, and upload it to a Windows SMB share. A History tab lists and views the images already on the share.

## Commands

- `flutter pub get` — fetch dependencies
- `flutter devices` / `flutter run -d <device-id>` — run on a device. The core flow needs real camera hardware and an SMB server on the LAN, so test on a physical device rather than an emulator.
- `flutter analyze` — static analysis (flutter_lints 6; platform dirs are already excluded in `analysis_options.yaml`)
- `flutter test` — run all tests; single file: `flutter test test/widget_test.dart`
- `flutter build apk` — release APK; currently signed with debug keys (see `android/app/build.gradle.kts`)

The Flutter SDK lives at `/home/dylan/Files/Develop/flutter` (useful when debugging the Gradle build).

## Architecture

The entire app is `lib/main.dart` — plain `StatefulWidget`s, no state-management library.

### Navigation model

- `HomePage` is the root shell: an `IndexedStack` holding the Scan (`ScannerPage`) and History (`HistoryPage`) tabs behind a `NavigationBar`. The History tab is built lazily (`_historyVisited`).
- The capture flow (`CameraPage` → `PreviewPage`) is pushed on top of the tab shell as separate routes. `popUntil((route) => route.isFirst)` returns to scanning; `pushReplacement` moves between capture stages so the stack stays shallow.
- `ScannerPage.paused` is set by the shell while the History tab is on top, stopping the camera via `didUpdateWidget`. `_onDetect` guards re-entry with `_processing` while the confirm dialog / capture flow is in flight.

### SMB layer

- Connection settings (host, `<share>/<sub-folder>` path, domain, user, password) are hardcoded constants at the top of `main.dart`. The share itself must already exist; sub-folders are created at upload time.
- Every operation (upload in `PreviewPage._upload`, listing in `HistoryPage._refresh`, download in `ImageViewerPage._load`) opens a fresh `SmbConnect.connectAuth` connection and closes it in a `finally`.
- Photos are captured via `image_picker` with no resize/compression; the original bytes are written to the share and the local capture deleted best-effort after success.
- When downloading, the `openRead` stream must be copied chunk-by-chunk into a `BytesBuilder` — smb_connect reuses one buffer for every chunk it yields. Don't "simplify" this.

### Filename contract (cross-feature invariant)

Uploads are named `{OrderNumber}_{YYYYMMDD}_{HHMMSS}.jpg`, timestamped when the upload starts (`PreviewPage._buildFileName`). `HistoryPage` depends on this exact format in two places: descending-name sort = newest first, and `_parseName` splits it back into (order number, readable date/time). Change both sides together or History breaks.

## Tests

`test/widget_test.dart` is a deliberate placeholder — the main flow requires camera hardware and a network share, so it cannot be a widget test.

<!-- BEGIN OPENSPEC SUPERPOWERS BRIDGE -->
<!-- Source: superpowers-bridge/templates/adopters/CLAUDE.md.fragment.md -->
<!-- Drop this section into your project's CLAUDE.md so Claude routes future work using this schema correctly. -->
<!-- Adjust the schema name and bridge repo URL if you customized them; otherwise keep as-is. -->

## Workflow routing (read on session start)

This repo uses [`superpowers-bridge`](https://github.com/JiangWay/openspec-schemas/tree/main/superpowers-bridge) to bridge OpenSpec and Superpowers. Integration rules (language, artifact paths, PRECHECK) follow that bridge's README; this section is the routing guidance for Claude.

### Entry routing

| Trigger you observe | What to do |
|---|---|
| User starts a narrative "design discussion / let's brainstorm" | Run verbal `superpowers:brainstorming`, but **do NOT** write to `docs/superpowers/specs/`. Once the conversation converges per the 5 criteria below, promote to `/opsx:propose` |
| User invokes `/opsx:new` / `/opsx:ff` / `/opsx:propose` directly | Follow the schema's flow; artifact instructions inject at each step |
| User explicitly says bug fix / typo / config tweak / doc update | Direct PR — **do NOT** open a change (see skip rules below) |
| User is mid-change | Advance with `/opsx:continue`, `/opsx:apply`, `/opsx:verify`, or `/opsx:archive` |

### When NOT to use opsx (direct PR)

| Scenario | Direct PR? |
|---|---|
| New feature / new capability / architectural change / breaking change | ❌ Use opsx |
| Bug fix (no contract change) / test backfill / linter tweak / non-breaking upgrade / typo / docs / config value tweak | ✅ Direct PR |

Principle: **process ceremony scales with risk**. External contracts / schema / cross-system integration / compliance → opsx. Otherwise → direct PR.

### Verbal brainstorm → opsx promotion criteria

All 5 must hold before promoting (any missing → keep brainstorming, **never** write to `docs/superpowers/specs/`):

1. **Scope locked** — one sentence describes what's in / out
2. **Major design forks resolved** — alternatives weighed; remaining TBDs have an owner and impact-scope statement
3. **Cross-system dependencies mapped** — ready / mockable / genuinely unknown — pick one per dep
4. **Acceptance criteria stateable** — concrete pass conditions (e.g., `./mvnw clean verify` passes + N deliverables)
5. **Conversation converging** — recent turns are confirmations, not new alternatives

When all 5 hold → proactively suggest "ready to `/opsx:propose`?" — wait for user ack. Never auto-trigger.

### Front-door anti-patterns (don't do)

- Letting brainstorming write to `docs/superpowers/specs/`
- Letting writing-plans write to `docs/superpowers/plans/`
- Promoting to opsx with unresolved blocking TBDs
- Opening a change for bug fix / typo

Full detail: [superpowers-bridge README §Entry & exit gates](https://github.com/JiangWay/openspec-schemas/blob/main/superpowers-bridge/README.md#entry--exit-gates).

<!-- END OPENSPEC SUPERPOWERS BRIDGE -->
