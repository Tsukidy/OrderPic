# order-folders delta — gallery-upload-option

## MODIFIED Requirements

### Requirement: Folder-targeted upload

When the per-order folders toggle is on, every uploaded photo MUST be
written into `{sharePath}/{orderNumber}/`, and that order folder MUST be
created if it does not already exist (best-effort, as today — the share
itself must pre-exist). When the toggle is off, uploads MUST be written
flat into `{sharePath}` exactly as before this change. Multiple photos of
the same order MUST therefore coexist in one dedicated folder when the
toggle is on. The placement rules MUST NOT depend on the capture source:
photos admitted from the device gallery MUST follow exactly the same
rules as photos taken with the camera.

#### Scenario: Folder mode writes into the order folder

- **WHEN** the folders toggle is on and a photo of order 100438 uploads
- **THEN** the file appears at `{sharePath}/100438/` and re-photos of the
  same order land in the same folder

#### Scenario: Folder mode off keeps flat writes

- **WHEN** the folders toggle is off and a photo uploads
- **THEN** the file appears directly in `{sharePath}` with no order folder
  created for it

#### Scenario: Gallery-sourced photos follow the folder setting

- **WHEN** the folders toggle is on and three photos picked from the
  gallery upload for order 100438
- **THEN** all three land in `{sharePath}/100438/` as if they had been
  taken with the camera

---
