# Fellow Stagg EKG Pro — Local HTTP Protocol

Everything here was **verified empirically against real hardware** (firmware on an
ESP32 / ESP‑IDF platform). The API is undocumented and unofficial — Fellow can
change it at any time. Commands are sent as plain HTTP `GET` requests:

```
GET http://<KETTLE_IP>/cli?cmd=<command>
Port: 80   ·   Response: plain text   ·   No auth
```

Spaces in a command are sent as `+` (e.g. `ss+S_Off`).

---

## Reading state — `cmd=state`

Returns plain‑text `key=value` lines. The fields that matter:

| Field | Meaning |
|---|---|
| `mode=` | State machine: `S_Off` / `S_Stby` (off), `S_Heat` (heating), `S_Hold` (keep‑warm / reached target) |
| `tempr=` | Current water temperature in °C. **Reads ~3 °C above the real water temp** — subtract an offset. Absent when the kettle is off its base. |
| `temprT=` | Target temperature in °C |
| `units=` | `1` = Celsius, `0` = Fahrenheit (numeric, not a letter) |
| `ho` | Heating element flag (momentary PWM/triac duty — can read 0 even while actively heating) |

Example:
```
mode=S_Heat
tempr=41.63 C
temprT=94.00 C
units=1
ketl= ho 0 wd 0 nw 0 ipb 0 bf 0 tr 0
```

---

## Power control

### ✅ Turn ON → `cmd=2`
`2` is a **short press of the dial button**. It is the **only** command that
actually engages the heating element (the water temperature rises). It is a
**toggle**, so only send it when the kettle is currently off — read `state`
first and verify the transition afterwards.

### ✅ Turn OFF → `cmd=ss S_Off`
`ss` (alias `setstate`) sets the state machine directly. `ss S_Off` is
**direct and idempotent** — no toggle ambiguity. Verify with a follow‑up `state`.

### ❌ Commands to AVOID

| Command | Why not |
|---|---|
| `heaton` / `heatoff` | Drive the heater GPIO **directly, bypassing the state machine** → the display and reported state desync. |
| `ss S_Heat` | Sets the *mode label* to `S_Heat` but does **not** engage the heater (`ho=0`, temperature does not rise). |
| `ss S_Heating` | Rejected by the firmware (`ret -1`). |

> Note: the firmware's reported heating mode and the token accepted by `ss`
> can differ between firmware revisions. On the tested unit, `ss S_Heat` was
> *accepted* but did not heat — which is exactly why `cmd=2` is used for ON.

---

## Setting the target temperature

### Direct — `cmd=setsetting settempr <F>`
The value is an **integer in degrees Fahrenheit** (not Celsius, not "2C"):

```
94 °C → 201        90 °C → 194        85 °C → 185
```

Send it, then read back `temprT` to confirm. On the tested unit this updated the
active target. (Some firmwares only update the *saved preference* — if `temprT`
doesn't change, fall back to the dial method below.)

### Fine adjustment — `cmd=q` / `cmd=w` (the dial)

| Command | Effect |
|---|---|
| `q` (or `left`) | Rotate dial left → −0.5 °C |
| `w` (or `right`) | Rotate dial right → +0.5 °C |

Each click is an exact **0.5 °C** step. Loop with verification to land on a
specific value.

---

## Recommended control strategy

- **ON:** read `state` → if off, send `2` → poll until `mode` leaves the off
  states (retry a few times).
- **OFF:** send `ss S_Off` → verify `mode` → retry if needed.
- **Set temp:** `setsetting settempr <F>` → verify `temprT` → fall back to
  dial (`q`/`w`) for the last fraction of a degree.
- **Robustness:** the kettle's HTTP server goes silent for several seconds during
  transitions (especially turning off). Tolerate a few consecutive failed polls
  before marking the device offline.
- **"Reached target":** detect the transition into `S_Hold`. Requires the
  kettle's **Hold** mode to be enabled.

---

## Other useful commands

| Command | Description |
|---|---|
| `prtsettings` | Print saved preferences (`settempr`, `hold`, `units`, `guide`, …) |
| `help` | List every CLI command the firmware supports |
| `setunitsc` / `setunitsf` | Switch display units to Celsius / Fahrenheit |
| `warmon` / `warmoff` | Keep‑warm mode on / off |
| `1` | Short press of button 1 (base button — opens the on‑device menu) |
