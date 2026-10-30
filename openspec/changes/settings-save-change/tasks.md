## 1. Write-through commit engine and tap controls

- [ ] 1.1 Failing widget test (red): in `test/settings_page_test.dart`, tapping the folders toggle — with NO Save press — updates `notifier.value.upload.useOrderFolders` AND writes `upload.use_order_folders` to the injected `InMemorySettingsStore`; same for the batch toggle and the format segment (PNG) / quality segment.
- [ ] 1.2 Implement the serialized commit queue in `_SettingsPageState` per design D2/D5: `_commitUpload` snapshots the notifier value, builds the new `UploadPrefs`, awaits `upload.save(store:)`, then assigns `settingsNotifier.value = current.copyWith(upload: new)`; chained through a `_pending` future so quick changes can't interleave; on store failure — notifier untouched, existing "Could not save settings" snackbar.
- [ ] 1.3 Rebuild the tap controls on it per design D2/D3: toggles and both segmented buttons read `widget.settingsNotifier.value.upload` and commit `onChanged`/`onSelectionChanged`; drop the `_folders`/`_batch`/`_format`/`_quality` fields; the quality block's JPEG-only mount test reads the notifier format (keep the `quality_section` key and the hide/show round-trip property, now via notifier state).
- [ ] 1.4 Widget tests (green + new): the rewritten former save-gated tests — format-to-PNG persists `upload.format: 'png'` on tap, quality preset persists on tap, quality selection survives the PNG hide/show round-trip, custom controls reveal for Custom — plus failure tests with a throwing `SettingsStore` fake: control still shows the old value, notifier unchanged, snackbar visible, and a subsequent successful commit lands the later value.

## 2. Slider and max-edge field timing

- [ ] 2.1 Slider per design D4: `onChanged` updates only the in-drag label state; `onChangeEnd` commits (persist + notifier). Widget test: releasing the slider persists exactly the released value (drag hook via `tester.dragFrom` then release, as today) and the custom pair round-trips through `UploadPrefs.load`.
- [ ] 2.2 Max-edge field per design D1/D4: commit on focus loss and on field submit (valid parse persists the number; blank persists null); keep the digits-only formatter and the fresh-construction rule for clearing back to null (no `copyWith` null-swallow). Widget tests: typed value persists on focus move to another field; blanking an existing cap clears it to null in store + notifier.
- [ ] 2.3 Close-time flush: the uncommitted field text is committed when the page closes — system back, and the Save pop — before controllers dispose. Widget test: enter "2048", pop the page without tapping the field's commit, reopen/inspect the store to find `upload.custom_max_edge: '2048'`.

## 3. Save = connection only; back and first-run unchanged

- [ ] 3.1 `_save()` per design D6: keep form validation, `_formSettings()`, the live-instance discipline (unchanged values reuse the current connection instance), `pop(true)` — but persist via `ConnectionSettings.save` (five `smb.*` keys) instead of `AppSettings.save`. Widget tests: Save persists username/password and pops (existing tests hold); a save that changes only the connection leaves every `upload.*` key at its last written value.
- [ ] 3.2 Widget tests for the back contract: gear mode — edit the host field, pop, reopen: fields show the original values, store and notifier unchanged (connection edits discarded); prefs toggled before backing out ARE persisted (the combination the change exists for).
- [ ] 3.3 First-run mode widget tests: with `firstRun: true`, a prefs toggle persists immediately while the gate is up; back stays blocked (`PopScope`) until a valid connection save; the valid save dismisses as today.
- [ ] 3.4 Update the stale doc comments the refactor orphans (`settings_page.dart` header comment "back discards edits", `_save`'s upload-half commentary) so they describe write-through prefs + connection-only Save; grep for references to the dropped fields.

## 4. Verification

- [ ] 4.1 `flutter analyze` clean and `flutter test` green across the suite — including `test/home_page_test.dart`'s History remount group (notifier-driven, expected untouched) and `test/app_settings_test.dart`/`test/upload_prefs_test.dart` (model layer unchanged).
- [ ] 4.2 Device pass (operator-gated): toggle each control and force-stop + relaunch → values persist; leave via back AND via Save → prefs never lost, connection edits discard on back; flip a pref while History was already visited → History neither remounts nor re-lists; capture with the changed prefs end-to-end.
