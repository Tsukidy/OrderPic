# order-folders Specification

## Purpose
Opt-in per-order folders on the SMB share, with a History that tells folders from photos at a glance and drills into an order's files.

## Requirements

### Requirement: Folder-targeted upload

When the per-order folders toggle is on, every uploaded photo MUST be
written into `{sharePath}/{orderNumber}/`, and that order folder MUST be
created if it does not already exist (best-effort, as today — the share
itself must pre-exist). When the toggle is off, uploads MUST be written
flat into `{sharePath}` exactly as before this change. Multiple photos of
the same order MUST therefore coexist in one dedicated folder when the
toggle is on.

#### Scenario: Folder mode writes into the order folder

- **WHEN** the folders toggle is on and a photo of order 100438 uploads
- **THEN** the file appears at `{sharePath}/100438/` and re-photos of the
  same order land in the same folder

#### Scenario: Folder mode off keeps flat writes

- **WHEN** the folders toggle is off and a photo uploads
- **THEN** the file appears directly in `{sharePath}` with no order folder
  created for it

---

### Requirement: Folder tiles in the History root listing

The History root listing MUST present directories as folder tiles that are
visually distinct from photos: a folder icon and a small grey "Folder"
label near the date/time area, with the folder (order) name as the title.
Directory detection MUST use the SMB entry's directory attribute, not name
heuristics. Folder tiles MUST be sorted by name descending and MUST appear
before the loose image files, which remain sorted newest-first as today.

#### Scenario: Order folder renders as a distinct tile

- **WHEN** the share root contains an order folder `100438` and loose
  images
- **THEN** the listing shows a folder tile titled `100438` with a folder
  icon and grey "Folder" label, positioned above the loose-image entries

#### Scenario: A photo is never mistaken for a folder

- **WHEN** the share root contains an image file whose name begins with an
  order-like number but the entry is a file
- **THEN** it renders as an image entry, because detection is
  attribute-based

---

### Requirement: Drill-down into an order folder

Tapping a folder tile MUST push a page that lists that folder's image
files — readable capture time as the title, file name as the subtitle,
formatted size as the trailing text — with pull-to-refresh available at
both the root and the folder level. Tapping a photo in the folder MUST
open the existing full-screen image viewer, which MUST be able to download
and display files residing in order folders.

#### Scenario: Drill-down lists an order's photos

- **WHEN** the operator taps the folder tile for order `100438`
- **THEN** a page titled for that order lists its photos newest-first with
  time, filename, and size

#### Scenario: Viewer displays a folder-resident photo

- **WHEN** the operator taps one of the photos inside the order folder
- **THEN** the full-screen viewer downloads and displays it exactly as it
  does for root-level files
