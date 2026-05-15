# Tests

Run everything from repo root:

    sh tests/run-all.sh

Each subdirectory has a `run.sh`:

- `tests/calc/`    — `mape-calc` golden-file regression
- `tests/proto/`   — netifd proto handler dry-run command capture
- `tests/fw/`      — `mape-fw` dry-run command capture
- `tests/extract/` — `extract-fc2-rules.sh` idempotency

Tests run on any POSIX shell with `awk`, `jsonfilter` (or `jq` for dev),
`iconv`, `diff`, and `sed`. CI uses Ubuntu (gawk) and Alpine (busybox awk).
