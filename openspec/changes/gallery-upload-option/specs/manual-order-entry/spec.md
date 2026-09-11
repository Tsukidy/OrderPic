# manual-order-entry delta — gallery-upload-option

## MODIFIED Requirements

### Requirement: Hand-off into the capture flow

Confirming a non-empty value MUST start the existing capture flow (camera
→ review → upload) with the typed order number, behaving identically to a
scanned code and without any further confirmation step. The dialog MUST
offer two confirm actions — Take photo and Gallery — sharing the same
empty-value gate, and either confirm MUST start the flow for the typed
order number with its chosen source. Scanning MUST resume when the flow
completes.

#### Scenario: Confirm starts the camera flow

- **WHEN** the operator types `100438` and confirms with Take photo
- **THEN** the camera flow starts and displays order `100438` in its order
  chip

#### Scenario: Gallery confirm starts the photo-picker flow

- **WHEN** the operator types `100438` and confirms with Gallery
- **THEN** the photo picker opens for a session of order `100438`, and
  picked photos flow into review exactly as they do from the scanned path

#### Scenario: Scanning resumes after the flow

- **WHEN** the capture flow finishes or is cancelled and returns to the
  Scan screen
- **THEN** the scanner is active again and can start another capture from
  either entry path

---
