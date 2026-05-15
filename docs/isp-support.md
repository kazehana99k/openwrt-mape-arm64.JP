# ISP Support Status

| ISP | Source | Auto-detect | Verified |
|---|---|---|---|
| BIGLOBE IPv6オプション (BR `2001:260:700:1::1:275`) | fc2 | ✅ | ✅ (fixture) |
| BIGLOBE IPv6オプション (BR `2001:260:700:1::1:276`) | fc2 | ✅ | algorithm-only |
| JPNE v6plus | fc2 | ✅ | algorithm-only |
| OCN バーチャルコネクト | fc2 | ✅ | algorithm-only |
| Asahi Net v6コネクト | — | ❌ (manual mode) | — |
| transix MAP-E | — | ❌ (manual mode) | — |
| So-net v6 | — | ❌ (manual mode) | — |

**"algorithm-only"** = parameters reproduce fc2 calculator output for the same
PD input, but no end-to-end packet test has been performed.

**Manual mode**: see README §"Manual configuration" (writes a v0.2 task).
