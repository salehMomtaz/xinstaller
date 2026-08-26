# xinstaller — versioning

xui-lite uses **integer versioning**: `v1`, `v2`, `v3`, ...

No semantic-version suffixes (`1.2.3`), no reusing the same bump for many
unrelated changes. One release = one integer bump = one git tag.

## Rules

- The current version lives in ONE place inside the script:

  ```bash
  readonly XUI_LITE_VERSION="1"
  ```

  Banner, cron header, and the final "SAVE THIS SCREEN" line all reference
  `v${XUI_LITE_VERSION}`, so there is no version string to drift out of sync.

- Every release:
  1. Increment `XUI_LITE_VERSION` and update the header changelog block.
  2. Commit the change.
  3. Tag it: `git tag v<N>` then `git push origin v<N>`.

## Why integer (history)

The script was previously labeled `v5.0.0` across ~14 distinct changes, then
`v6.1.0` — the version string said nothing about what actually changed. Integer
bumps make each release unambiguous: `v1` is the baseline imported from the
settled, hardened working copy; `v2`, `v3`, ... are future single-purpose
releases.

## Baseline note (v1)

`v1` was bootstrapped from the most complete working copy
(`/home/dev/mimo/xui-lite.sh`, previously self-described v6.1.0). The old
`5.0.0` / `6.1.0` labels are intentionally dropped. This tag is the canonical
starting point from which future integer releases derive.