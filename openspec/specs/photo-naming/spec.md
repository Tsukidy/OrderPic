# photo-naming Specification

## Purpose
The cross-feature filename contract: capture-time stamped, collision-proof names for every upload, and the dual-shape parsing and ordering History depends on.

## Requirements

### Requirement: Capture-time filename scheme

Every admitted shot MUST be assigned its final filename at admission:
`{OrderNumber}_{YYYYMMDD}_{HHMMSS}_{NNN}.{ext}`, where the timestamp is
the admission moment, `NNN` is the zero-padded three-digit shot index
within the capture session (starting at 001), and the extension is `jpg`
or `png` per the format in effect at admission. The filename MUST NOT
change if the upload is later retried, and two shots admitted within the
same second MUST receive distinct indexes rather than colliding.

#### Scenario: First shot of a session is indexed 001

- **WHEN** a photo of order 100438 is admitted at 2026-09-08 14:03:05 as
  the first shot of its session
- **THEN** its filename is `100438_20260908_140305_001.jpg`

#### Scenario: Same-second shots do not collide

- **WHEN** two shots of the same order are admitted within the same second
- **THEN** they are indexed `NNN` = 001 and 002 and both files exist after
  upload

#### Scenario: Retried upload keeps its filename

- **WHEN** a shot's upload fails and the operator retries it minutes later
- **THEN** the uploaded file carries the name assigned at admission, not a
  name restamped at retry time

---

### Requirement: Legacy and new name parsing

The History name parser MUST accept both the legacy three-part shape
`{Order}_{YYYYMMDD}_{HHMMSS}.ext` and the new four-part shape
`{Order}_{YYYYMMDD}_{HHMMSS}_{NNN}.ext`, yielding the order number and a
readable date/time for each. Files it cannot parse MUST fall back to
showing the raw filename, as today.

#### Scenario: Legacy filename still parses

- **WHEN** History lists a pre-change file named
  `100438_20260901_101530.jpg`
- **THEN** it is displayed with order number 100438 and readable time

#### Scenario: New-shape filename parses

- **WHEN** History lists a file named `100438_20260908_140305_003.jpg`
- **THEN** it is displayed with order number 100438 and readable time,
  ignoring the index for display purposes

---

### Requirement: Newest-first ordering across schemes

History listings MUST order image files by descending filename, which MUST
remain a correct newest-first ordering for legacy and new names alike
(within one order's folder listing, newest-first by the same rule).

#### Scenario: Mixed-age files sort newest-first

- **WHEN** a listing contains legacy and new-shape files captured on
  different dates
- **THEN** descending filename order presents them newest-first regardless
  of shape
