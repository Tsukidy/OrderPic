## ADDED Requirements

### Requirement: Manual entry affordance on the Scan screen

The Scan screen MUST present a "Type order number" control that is visible
and tappable whenever QR scanning is active, so an operator who cannot scan
a code can start the capture flow without leaving the screen.

#### Scenario: Affordance visible while scanning

- **WHEN** the Scan screen is showing with the camera active
- **THEN** a "Type order number" control is visible and opens the manual
  entry dialog when tapped

---

### Requirement: Numeric-only order number input

The manual entry field MUST accept digits (0–9) only — whether typed or
pasted — and MUST limit the value to at most 16 digits.

#### Scenario: Non-digit characters are rejected

- **WHEN** the operator types or pastes any character other than 0–9 into
  the entry field
- **THEN** that character does not enter the field

#### Scenario: Length is capped

- **WHEN** the field already holds 16 digits and more digits are entered
- **THEN** the field content is unchanged

---

### Requirement: Empty-value confirmation gate

The entry dialog's confirm action MUST be disabled whenever the trimmed
field value is empty.

#### Scenario: Confirm disabled when empty

- **WHEN** the entry dialog is open and the field is empty
- **THEN** the confirm action is disabled

#### Scenario: Confirm enabled with input

- **WHEN** the field holds at least one digit
- **THEN** the confirm action is enabled

---

### Requirement: Cancellation resumes scanning

Dismissing the entry dialog — via cancel or backdrop — MUST NOT start the
capture flow, and MUST leave the scanner in a state where barcode detection
works normally.

#### Scenario: Cancel does not start the flow

- **WHEN** the operator dismisses the entry dialog without confirming
- **THEN** no route is pushed and scanning continues

#### Scenario: Detection works after cancel

- **WHEN** a readable QR code is presented after the entry dialog was
  dismissed
- **THEN** the QR confirmation dialog appears as it does today

---

### Requirement: Barcode detection suppressed during entry

While the manual entry dialog is open, barcode detection MUST NOT trigger
the QR confirmation flow.

#### Scenario: QR in view while dialog is open

- **WHEN** a readable QR code is in camera view while the entry dialog is
  open
- **THEN** no QR confirmation dialog appears on top of the entry dialog

---

### Requirement: Hand-off into the capture flow

Confirming a non-empty value MUST start the existing capture flow (camera →
review → upload) with the typed order number, behaving identically to a
scanned code and without any further confirmation step, and scanning MUST
resume when the flow completes.

#### Scenario: Confirm starts the camera flow

- **WHEN** the operator confirms the value `100438`
- **THEN** the camera flow starts and displays order `100438` in its order
  chip

#### Scenario: Scanning resumes after the flow

- **WHEN** the capture flow finishes or is cancelled and returns to the
  Scan screen
- **THEN** the scanner is active again and can start another capture from
  either entry path

---

### Requirement: Upload naming contract preserved

An upload started from a manually entered order number MUST produce a file
named per the existing contract
`{OrderNumber}_{YYYYMMDD}_{HHMMSS}.jpg`, which History can parse into order
number and readable date/time.

#### Scenario: Manually entered order produces a parseable filename

- **WHEN** an upload for manually entered order `100438` completes
- **THEN** the share contains a file matching
  `100438_{YYYYMMDD}_{HHMMSS}.jpg` and the History tab lists it with order
  number `100438` and a readable date/time
