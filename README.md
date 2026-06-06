# BioPulse Tile — a tiny vital-sign radar detector

[![tinytapeout](https://img.shields.io/badge/Tiny%20Tapeout-project-blue)](https://tinytapeout.com)

`tt_um_roberto_tiny_radar_tile` turns a single 8-bit radar/biosignal sample
stream into vital-sign events and a breathing-rate number — entirely in
digital logic, no CPU and no software. It detects and classifies breathing
(normal / fast / slow / irregular), flags apnea, detects a heartbeat band, and
computes breaths-per-minute.

A built-in demo mode generates synthetic breathing patterns (plus a heartbeat
ripple), so the design can be shown on the demo board with LEDs and no
external analog front-end.

## Architecture

```
sample (ui_in / demo) ─► baseline EMA ─► breathing detect ─► classify FSM
        │                 fast    EMA ─► heartbeat detect
        └─────────────────────────────► breaths-per-minute (long divider)
```

One sample is processed per clock.

## Pinout

| Group | Pin       | Function                                         |
|-------|-----------|--------------------------------------------------|
| in    | `ui[7:0]` | 8-bit radar/biosignal sample (external)          |
| out   | `uo[7:0]` | status flags, or breaths-per-minute when `uio[2]=1` |
| bidir | `uio[0]`  | demo mode enable (in)                            |
| bidir | `uio[1]`  | sensitivity select (in)                          |
| bidir | `uio[2]`  | BPM readout select (in)                          |
| bidir | `uio[4:3]`| demo pattern select (in)                         |
| bidir | `uio[7:5]`| coarse breaths-per-minute bargraph (out)         |

Status flags on `uo_out` (when `uio[2]=0`): `[0]` breathing, `[1]` apnea,
`[2]` fast, `[3]` slow, `[4]` irregular, `[5]` heartbeat, `[6]` above baseline,
`[7]` valid. Demo patterns (`uio[4:3]`): `00`=normal, `01`=fast, `10`=slow,
`11`=apnea.

## How to test

```
cd test
make
```

Covers reset, the four demo patterns, the heartbeat detector, the
breaths-per-minute readout, and external-input mode.

## License

Apache-2.0. See [LICENSE](LICENSE).
