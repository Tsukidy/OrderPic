# manual-order-entry delta — folder-bundling

## MODIFIED Requirements

### Requirement: Upload naming contract preserved

An upload started from a manually entered order number MUST produce a file
named per the capture-time filename scheme
`{OrderNumber}_{YYYYMMDD}_{HHMMSS}_{NNN}.jpg|.png` — timestamped when the
shot is admitted, indexed within the capture session, with the extension
following the configured image format — which History can parse into order
number and readable date/time (see the photo-naming capability).

#### Scenario: Manually entered order produces a parseable filename

- **WHEN** an upload for manually entered order `100438` completes
- **THEN** the share contains a file matching
  `100438_{YYYYMMDD}_{HHMMSS}_{NNN}.jpg|.png` and the History tab lists it
  with order number `100438` and a readable date/time

#### Scenario: A second manual-entry shot of the same order indexes onward

- **WHEN** the operator starts another capture for manually entered order
  `100438` and uploads one shot from that new session
- **THEN** that shot's filename carries its own session's index (001),
  distinct timestamp, and does not overwrite the earlier file
