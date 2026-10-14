# Draconic Reactor Controller (standalone)

Independent control computer for a Draconic Evolution reactor. Lives in its own
folder with frozen API duplicates, so the main `Program/` updates never break it.
Logic follows the proven `drmon` algorithm (acidjazz / Dragonbones-reap,
`DEReactor_1.20.1`), adapted to the Kenzu WS gateway + touch UI + settings files.

## Wiring (wired modems only, like the original)

- 1× Advanced Computer + 3×3 Advanced Monitors (one modem anywhere on the net).
- 1× modem on the **input flux gate** (the gate feeding the reactor energy injector).
- The **output flux gate** must touch the computer directly (any side).
- The reactor stabilizer must also touch the computer directly (any free side).
- All modems linked with network cable into one wired network.
- If gates get mixed up, use the SWAP logic below (or set names explicitly).

No wireless/Ender modem is needed for control itself; internet (HTTP) is only
used for the website uplink via `gateway.lua`.

## Install

```text
wget run https://raw.githubusercontent.com/kenzu926/kenzu_cc/refs/heads/main/Draconic/installer.lua wss://YOUR_HOST/ws <same-token-as-everywhere>
reboot
```

`startup` launches: Gateway, Draconic (controller), Monitor Relay (if a monitor
is present), Files.

## Monitor UI (3x3, touch)

- Tab **STATUS**: state, generation RF/t, temperature, saturation / field /
  fuel bars, gate flows, last action.
- Tab **CONTROL**: output gate −100k/−10k/−1k/+1k/+10k/+100k, input gate same
  (manual mode only) + AUTO/MAN toggle, target field −5/+5, CHARGE/STOP/START.

## Automation (`draconic.settings`, survives reboot)

| Key | Default | Meaning |
|---|---|---|
| `draconic.targetStrength` | 50 | Hold field at this % (`flow = drain / (1 − target/100)`) |
| `draconic.maxTemperature` | 8000 | STOP above, re-START below `safeTemperature` |
| `draconic.safeTemperature` | 3000 | Restart threshold after overheat |
| `draconic.lowFieldPercent` | 15 | STOP + CHARGE below this field while online |
| `draconic.fuelMinPercent` | 10 | STOP when fuel remaining drops below |
| `draconic.activateOnCharged` | true | Auto START after `charged` |
| `draconic.autoInput` | true | Auto input-gate regulation (else `manualInput`) |
| `draconic.manualInput` | 222000 | Manual input flow |
| `draconic.outputGate` / `draconic.inputGate` | "" | Explicit gate names (else auto: first two `flow_gate`, output = first) |
| `draconic.monitor` | `monitor_0` | Monitor for the UI |

Gate assignment: if auto-pick is wrong (output and input swapped), set the two
names explicitly — either in `draconic.settings` or via the website Files tab.

## API / versions

- Reactor peripheral type: `draconic_reactor` (`getReactorInfo`, `chargeReactor`,
  `stopReactor`, `activateReactor`); gates: `flow_gate` (`getSignalLowFlow`,
  `setSignalLowFlow`). All calls are `pcall`-guarded: unknown fields show as
  `--`/`offline` instead of crashing.
- Researched against `Dragonbones-reap/DEReactor_1.20.1` (drmon fork targeting
  1.20.1) and the classic `acidjazz/drmon`. The DE computer API did not change
  between these versions; the defensive reads above cover any subset.
- `Draconic/*.lua` API files are byte-duplicates of `Program/` at creation time.
  After big shared changes, re-copy them manually.
- Telemetry role `draconic` (`draconic_status`) is accepted by the site gateway;
  website widgets are a future step.
