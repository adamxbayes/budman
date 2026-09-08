# BudsControl

A macOS menu bar app for controlling the noise-control mode on Samsung Galaxy Buds
from a Mac — the ANC / Ambient / Adaptive switch that otherwise only exists in the
Galaxy Wearable app on a Samsung phone.

Built and verified against **Galaxy Buds3 Pro**, firmware `R630XXU0AYJ1`.

## What it does

- Shows the current mode in the menu bar (`OFF` / `ANC` / `AMB` / `ADP`)
- Switches between Off, Adaptive, Ambient sound and Noise cancelling
- Ambient level and ambient tone sliders (0–4), with an optional separate level per ear
- Shows battery for each earbud and the case, plus whether each bud is in your ear
- Toggles Voice detect (auto-switch to ambient when you start talking)
- Rings the earbuds to find them
- Global shortcut **⌥⇧A** cycles ANC → Ambient → Off
- **Control Center controls** (macOS 26): a noise-control button plus ANC and
  ambient toggles you can place in Control Center or directly in the menu bar
- Reconnects on its own when the earbuds come back in range

## Install

Requires macOS 26 and Xcode 26 (the Control Center extension needs both; the
command-line tools alone are not enough).

```bash
git clone https://github.com/adamxbayes/budman.git
cd budman
./build.sh
cp -R build/BudsControl.app /Applications/
open /Applications/BudsControl.app
```

Run it from `/Applications` — that is what makes macOS register the Control
Center extension. `build.sh` regenerates the Xcode project from `project.yml` if
[xcodegen](https://github.com/yonaskolb/XcodeGen) is installed and otherwise uses
the committed one, so xcodegen is only needed if you change the project layout.

### Adding the controls to Control Center

Open Control Center from the menu bar, choose **Edit Controls** at the bottom,
and look for **Buds Control**. Three controls are offered:

| Control | Does |
|---|---|
| Galaxy Buds noise control | Shows the current mode; press to cycle ANC → Ambient → Off |
| Galaxy Buds noise cancelling | Toggle |
| Galaxy Buds ambient sound | Toggle |

The same editor lets you pin any of them to the menu bar itself, which is a good
answer to a notch-crowded menu bar. The app has to be running for the controls to
work — they show *Not connected* otherwise — so leave **Open at login** on.

macOS asks for Bluetooth permission on first launch. Building it yourself is the
point: the app is ad-hoc signed, not notarised, so a copy downloaded from
somewhere else would be blocked by Gatekeeper, while one built on your own machine
runs without fuss. The permission grant is tied to the signature and path, so
rebuilding in place keeps it but moving the app may prompt again.

The app is not affiliated with or endorsed by Samsung.

To start it automatically, use **Open at login** in the menu.

To troubleshoot, run it with tracing on:

```bash
open -n build/BudsControl.app --stderr /tmp/buds.log --env BUDSCTL_DEBUG=1 && tail -f /tmp/buds.log
```

## How it works

The earbuds expose a proprietary Bluetooth Classic serial service alongside the
usual A2DP/HFP audio profiles:

| | |
|---|---|
| Service name | `GEARMANAGER` |
| Service UUID | `2e73a4ad-332d-41fc-90e2-16bef06523f2` |
| Transport | RFCOMM (channel 27 on this pair; discovered from SDP at runtime) |

Everything runs over that channel as length-prefixed, CRC-checked frames:

```
FD <len-lo> <len-hi> <msg-id> <payload…> <crc-lo> <crc-hi> DD
```

The 16-bit length counts the message id, payload and CRC. Bit 12 marks a response
and bit 13 a fragment. The CRC is CRC-16/CCITT with a zero seed over the message id
plus payload, stored little-endian.

After the channel opens, sending `MANAGER_INFO` (136) makes the earbuds push their
full state as `EXTENDED_STATUS_UPDATED` (97). Writing `NOISE_CONTROLS` (120) with a
single mode byte — `0` off, `1` noise cancelling, `2` ambient, `3` adaptive — changes
the mode, and the earbuds reply with an acknowledgement (66). Changing the mode by
pinching an earbud pushes `NOISE_CONTROLS_UPDATE` (119), so the menu stays in sync.

### Ambient level

Ambient loudness is `AMBIENT_VOLUME` (132) with a single byte, `0`–`4`. Separate
per-ear levels and the tone go through `CUSTOMIZE_AMBIENT_SOUND` (130) as
`[enabled, left, right, tone]`, each `0`–`4`.

The two messages behave differently and the app compensates for it:

- **132 is not validated by the earbuds.** They store whatever byte you send —
  writing `255` sticks — so the app clamps to `0`–`4` before sending. The
  factory value on this pair was `4`, which is what fixes the top of the range.
- **130 is validated.** Any component above `4` makes the earbuds ignore the
  whole message and leave their state untouched.

When per-ear levels are on, the earbuds use those and ignore the single level,
so the menu shows one set of sliders or the other, never both.

### No ANC level control

There is no ANC intensity on the Buds3 Pro. `NOISE_REDUCTION_LEVEL` (131) is
accepted and acknowledged, and the byte it writes is even visible at offset 24 of
the status message, but the earbuds never validate or clamp it — `255` is stored
as readily as `1`. GalaxyBudsClient reaches the same conclusion from the other
direction: its `AncNoiseReductionLevels` feature is declared for Buds Pro, Buds FE,
Buds Core and Buds3 FE, and deliberately not for the Buds3 Pro. So the app does not
offer a slider that would not do anything. Noise cancelling is on, off, or adaptive.

### Verified payload offsets

These come from `EXTENDED_STATUS_UPDATED` on Buds3 Pro revision 4. Each one was
confirmed by changing the setting and re-reading the message, rather than assumed:

| Offset | Meaning |
|---|---|
| 0 | protocol revision (4) |
| 2 / 3 | left / right battery percentage |
| 6 | placement, high nibble left, low nibble right (1 = in ear, 2 = out, 3 = in case) |
| 7 | case battery percentage |
| 12 | noise-control mode |
| 23 | ambient level |
| 26 | voice detect on/off |
| 29 | separate-level-per-ear on/off |
| 30 | per-ear ambient level, high nibble left, low nibble right |
| 36 | ambient tone |

Message ids and the framing rules were cross-checked against
[GalaxyBudsClient](https://github.com/timschneeb/GalaxyBudsClient), which documents
the protocol across the whole Galaxy Buds range. This app shares no code with it —
only the protocol facts — and is released under the MIT licence.

### Control Center plumbing

Controls run in a WidgetKit extension — a separate, sandboxed process that
cannot use the app's Bluetooth channel. The two sides talk over distributed
notifications in both directions, with the payload encoded in the notification
*name* (`…setMode.1`, `…cycle`, `…query` one way; `…state.<connected>.<mode>`
the other). Two constraints shaped that:

- A sandboxed process may post distributed notifications, but macOS strips the
  `userInfo` dictionary, and the centre only delivers names it was asked for
  explicitly — a nil name is not a wildcard. Both vocabularies are small and
  closed, so each side simply registers every name it understands.
- The conventional alternative, shared app-group defaults, needs an entitlement
  that Xcode will only sign with a provisioning profile, which would tie the build
  to an Apple developer account. Notifications need no entitlements, so an ad-hoc
  signature is enough and anyone can build it.

When Control Center is about to draw a control it asks the app for the current
state and waits up to 400 ms for an answer; silence means the app is not running.

## Layout

| Path | Purpose |
|---|---|
| `App/Protocol.swift` | Framing, CRC, message ids, status decoding |
| `App/BudsLink.swift` | Device discovery, RFCOMM channel, reconnect, commands |
| `App/StatusBar.swift` | Menu bar item, menu, global shortcut, Control Center listener |
| `App/SliderRow.swift` | Slider inside a menu item |
| `App/main.swift` | Application entry point |
| `Controls/BudsControls.swift` | Control Center controls and their intents |
| `Shared/NoiseMode.swift` | Mode enum, compiled into both targets |
| `Shared/ControlBridge.swift` | App ↔ extension protocol |
| `project.yml` | xcodegen project definition |

## Limits

- Bluetooth Classic RFCOMM only — the earbuds must be paired and in range.
- Mode changes are refused by the earbuds while they are in the case; the app shows whatever they report back.
- Only the settings listed above are implemented. The protocol carries far more
  (equaliser, touch controls, spatial audio, firmware updates); the message ids for
  those are in `GalaxyBudsClient` if you want to extend this.
- Offsets are verified for Buds3 Pro. Other models share the framing but shift the
  status layout, so battery and mode positions would need re-checking per model.
