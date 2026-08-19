<!-- markdownlint-disable -->
## Description

<!-- Briefly describe what this PR does and link the relevant issue(s). -->

Closes #

## Type of Change

<!-- Mark the options you actually changed, delete the rest. -->

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to change)
- [ ] Documentation update
- [ ] Localization / translation update
- [ ] Refactor (no functional change)
- [ ] Build / tooling / CI

## Affected Area

<!-- Tick the parts of the project this PR touches so reviewers can route it faster. -->

- [ ] Capture (area / full-screen / delayed / scrolling)
- [ ] Recording (video / GIF)
- [ ] Annotation tools
- [ ] OCR / Translation
- [ ] Pin / Pin library
- [ ] Watermark
- [ ] Global shortcuts / Preferences
- [ ] Permissions (screen / mic / accessibility)
- [ ] Build / packaging scripts
- [ ] Documentation / README / translations
- [ ] Other: ___

## Implementation Notes

<!-- What did you do, why, and what tradeoffs did you consider? -->

## Test Plan

<!-- How did you verify the change? List the exact reproduction steps and the observed result. -->

1.
2.
3.

### Manual Verification on macOS

| Check | Result |
|-------|--------|
| Tested on macOS 13 | yes / no |
| Tested on macOS 14 | yes / no |
| Tested on macOS 15 | yes / no |
| Both Apple Silicon and Intel | yes / no |
| `swift test --disable-sandbox` passes | yes / no |
| `swift build --disable-sandbox` passes | yes / no |
| `scripts/build-dmg.sh` produces a launchable DMG | yes / no |

### Screenshots / Recordings

<!-- Drag images into the PR description or paste `![](path)` references. -->

## Checklist

- [ ] I have read [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] I have run `swift test --disable-sandbox` and the suite is green
- [ ] My change does not introduce new permission prompts without justification
- [ ] I have updated the relevant `README.*.md` and `Resources/<locale>.lproj/InfoPlist.strings` when copy or new UI strings changed
- [ ] Existing global shortcuts that may now collide have been re-checked
