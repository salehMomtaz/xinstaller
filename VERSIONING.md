# xinstaller — versioning

`xinstaller` uses **integer versioning**: `v1`, `v2`, `v3`, ...

No semantic-version suffixes (`1.2.3`), no reusing the same bump for many
unrelated changes. One release = one integer bump = one git tag.

## Rules

- The current version lives in ONE place inside the script:

  ```bash
  readonly XINSTALLER_VERSION="2"
  ```

  The banner, cron header, and the final "SAVE THIS SCREEN" line all reference
  `v${XINSTALLER_VERSION}`, so there is no version string to drift out of sync.

- Every release:
  1. Increment `XINSTALLER_VERSION` and update the header changelog block.
  2. Commit the change.
  3. Tag it: `git tag v<N>` then `git push origin v<N>`.

## History

| Version | Author              | Notes |
| ------- | ------------------- | ----- |
| v0      | qwen3.7plus         | Original `xui-lite` script lineage (pre-integer-versioning). |
| v1      | deepseek-v4-pro-0813 | Integer-versioning baseline: canonical, hardened working copy imported and tagged. |
| v2      | deepseek-v4-pro-0813 | Project and script renamed from `xui-lite` to `xinstaller`; all internal names and artifact paths migrated. |

## Why integer (history)

The script was previously labeled `v5.0.0` across ~14 distinct changes, then
`v6.1.0` — the version string said nothing about what actually changed. Integer
bumps make each release unambiguous: `v1` was the baseline imported from the
settled, hardened working copy, and `v2`, `v3`, ... are single-purpose releases.

## Rename note (v2)

Before v2 the project was named `xui-lite` and the script `xui-lite.sh`. In v2
both became `xinstaller` / `xinstaller.sh`, and every in-script name, artifact
path (nginx vhost prefix, fakesite prefix, cron file, maintenance scripts,
manifest, log and session files) was migrated to match.