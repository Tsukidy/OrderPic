## ADDED Requirements

### Requirement: Recent button on the Scan screen

The Scan screen MUST present a "Recent" control beside the "Type order
number" control, in the same bottom row, that is always visible. The
control MUST be disabled while no order number has been recorded and MUST
be enabled once at least one order number has been recorded, without
requiring the operator to leave the screen.

#### Scenario: Disabled before the first capture

- **WHEN** the Scan screen is showing and no order number has been
  recorded yet
- **THEN** the Recent control is visible but disabled

#### Scenario: Enabled after a capture starts

- **WHEN** a capture has been started for any order number from any entry
  path and the Scan screen is shown again
- **THEN** the Recent control is enabled

---

### Requirement: Recording confirmed capture starts

Every confirmed capture start MUST record its order number as the most
recent entry, where "confirmed capture start" means the capture flow
actually launches (the capture session is created) from the QR-scan
confirm, the manual entry confirm, or a recents pick. Merely scanning or
typing a number that is dismissed, or a capture start whose session fails
to be created, MUST NOT record anything.

#### Scenario: QR-confirmed order records

- **WHEN** the operator scans a QR code and confirms with Take photo or
  Gallery, and the capture flow starts
- **THEN** that order number is recorded as the most recent entry

#### Scenario: Manually entered order records

- **WHEN** the operator types an order number and confirms with Take
  photo or Gallery, and the capture flow starts
- **THEN** that order number is recorded as the most recent entry

#### Scenario: Dismissed scan does not record

- **WHEN** the operator scans a QR code and dismisses the confirm dialog
  (Rescan or backdrop)
- **THEN** no order number is recorded

#### Scenario: Failed capture start does not record

- **WHEN** an order number is confirmed but creating the capture session
  fails
- **THEN** no order number is recorded

---

### Requirement: Most-recent-first ordering with deduplication

The recorded list MUST present the most recently captured order number
first. Re-recording an order number already in the list MUST move it to
the front rather than duplicating it.

#### Scenario: Newest entry first

- **WHEN** the operator captures for order `A`, then for order `B`
- **THEN** the list reads `B` then `A`

#### Scenario: Re-used order moves to the front

- **WHEN** the list reads `B` then `A`, and the operator captures again
  for order `A`
- **THEN** the list reads `A` then `B`, with no duplicate `A`

---

### Requirement: Bounded list size

The list MUST hold at most 10 order numbers. Recording an eleventh
distinct order number MUST evict the oldest entry, and the persisted
payload MUST be rewritten in whole at each recording so its size never
grows with usage.

#### Scenario: Oldest entry is evicted

- **WHEN** the list already holds 10 order numbers and a new distinct
  order number is recorded
- **THEN** the list holds 10 order numbers with the new one first and the
  previous oldest no longer present

#### Scenario: Re-recording never grows the list

- **WHEN** the list holds 10 order numbers and an order already in the
  list is recorded again
- **THEN** the list still holds the same 10 order numbers

---

### Requirement: Persistence across restarts

The recorded list MUST persist per device across app restarts, and MUST
be stored through the same injectable settings-store seam the app already
uses (one key holding the whole list), without adding any entry to the
`AppSettings` umbrella. When the stored payload is unreadable or
corrupt, the app MUST fall back to an empty list without deleting or
altering any other stored keys.

#### Scenario: List survives an app restart

- **WHEN** the operator captures for order `100438`, closes and reopens
  the app, and opens the recents picker
- **THEN** `100438` is offered

#### Scenario: Corrupt store degrades without collateral damage

- **WHEN** the recents key holds an unreadable or corrupt payload and the
  app starts
- **THEN** the Recent control starts disabled (empty list) and the
  settings keys for other features are unchanged

---

### Requirement: Recents picker dialog

Tapping the enabled Recent control MUST open a picker dialog listing the
recorded order numbers, most-recent first. While the picker dialog is
open, barcode detection MUST NOT trigger the QR confirmation flow, and
dismissing the picker MUST NOT start any capture flow and MUST leave the
scanner in a state where barcode detection works normally.

#### Scenario: Picker lists recorded numbers

- **WHEN** the operator taps the enabled Recent control
- **THEN** a dialog lists the recorded order numbers, most-recent first

#### Scenario: No QR dialog while picker is open

- **WHEN** a readable QR code is in camera view while the picker dialog
  is open
- **THEN** no QR confirmation dialog appears on top of the picker

#### Scenario: Dismissing the picker resumes scanning

- **WHEN** the operator dismisses the picker without picking
- **THEN** no route is pushed and a later readable QR code opens the QR
  confirmation dialog as usual

---

### Requirement: Pick hands off into the existing capture flow

Picking an order number from the picker MUST offer the same two confirm
actions — Take photo and Gallery — and either confirm MUST start the
existing capture flow (camera → review → upload) for the picked order
number, behaving identically to a scanned code, including the
capture-time filename contract and session behavior owned by the existing
capabilities (see `manual-order-entry`, `photo-naming`, `batch-capture`).
Cancelling that confirm MUST NOT start any flow and MUST leave the
scanner in a state where barcode detection works normally.

#### Scenario: Picked order starts the camera flow

- **WHEN** the operator picks `100438` from the picker and confirms with
  Take photo
- **THEN** the camera flow starts and displays order `100438` in its
  order chip, exactly as a scanned `100438` would

#### Scenario: Picked order starts the gallery flow

- **WHEN** the operator picks `100438` from the picker and confirms with
  Gallery
- **THEN** the photo picker opens for a session of order `100438`, and
  picked photos flow into review exactly as they do from the scanned path

#### Scenario: Cancelling the confirm resumes scanning

- **WHEN** the operator picks an order number and then cancels the
  Take photo / Gallery confirm dialog
- **THEN** no route is pushed, the cancelled pick records nothing (its
  number keeps only the position any earlier capture gave it), and a
  later readable QR code opens the QR confirmation dialog as usual

#### Scenario: Picked-order uploads follow the naming contract

- **WHEN** an upload for picked order `100438` completes
- **THEN** the share contains a file matching
  `100438_{YYYYMMDD}_{HHMMSS}_{NNN}.jpg|.png` per the photo-naming
  capability
