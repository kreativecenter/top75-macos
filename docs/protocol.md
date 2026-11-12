# TOP75 USB protocol and verification

The Windows package `Darmoshark_setup_2.1.83(WIN2024124).exe` (SHA-256 `b32c4eb0cac2a08f96ced38fb3e43783d66466e1092f1e728a18cc097a9d254b`) was inspected statically. The model registry and command builders in its renderer identify the `yc500_top75_soc` variant, ID 957 and a 128 × 128 RGB565 display with five still slots. The proprietary installer and its contents are not redistributed.

The USB device exposes feature report ID 0 on VID `0x3151`, PID `0x4015`, usage page `0xFFFF` and usage `2`. The app requires an exact response to the identify command before every transaction. It sends 64-byte feature reports through IOKit. The checksum is the bitwise complement of the wrapping byte sum. Normal reports place it in byte 7 and the global LED setter uses byte 8. Reports and requests run serially.

| Operation | Commands |
| --- | --- |
| Device identification | `8F` |
| Active profile | `85` read, `05` write |
| Global lighting | `87` read, `07` write |
| Per-key color | `8C` read pages, `14` write one slot |
| Base and Fn maps | `89` and `90` read pages, `13` and `15` write one slot |
| Macro | `8B` read pages, `16` write pages and commit |
| Debounce | `91` read, `11` write |
| Sleep timers | `92` read, `12` write |
| OS detection | `97` read, `17` write |
| Screen | `A5` prepare and poll, `25` send 56-byte pages |

Device reads verified real writes for lighting, profiles, the base and Fn maps, a single LED color, a short keyboard macro, debounce and a sleep timer. The original settings were restored after these tests. A forced five-page macro write caused a USB re-enumeration on the test unit. The implementation now follows the populated-page write pattern, limits the encoded macro size, and checks the returned bytes. A subsequent short write and clear round-tripped successfully. A still upload was exercised on a user-designated slot. The device owner confirmed that a still image uploaded from the app appeared on the keyboard display. Transport acknowledgement verifies submission of the bytes. The app has no image readback.

The [sharkfin protocol documentation](https://github.com/dniminenn/sharkfin/blob/master/docs/PROTOCOL.md) cross-checks the yc500 report envelope, checksum, and operation families. Its other hardware variants are outside this release's device matching.

A two-page keyboard macro ending at a 56-byte write boundary was verified on the connected TOP75 with 150 ms between writes and 700 ms before readback. The writer includes all four terminating bytes in the write and verification. The test slot was cleared afterward.

The restore preview compares the version 1 JSON backup with current settings on the same firmware. Applying a selection rereads the relevant state, verifies each write and returns to the entry profile before applying device-wide settings. The batch color editor writes each selected RGB slot with 250 ms pacing and reads back the selected colors. The display preview decodes the same RGB565 frames passed to the uploader. Automated checks cover the JSON selection and the fit/crop rendering of a two-frame GIF. The new batch color and restore paths still need testing on the physical keyboard.
