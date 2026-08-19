# Security Policy

Brushot requests some of the most sensitive permissions on macOS — screen capture, system audio, microphone, and (optionally) accessibility. We take bugs that affect those surfaces seriously.

## Supported Versions

| Version | Supported |
|---------|-----------|
| `main` branch | ✅ |
| Latest release | ✅ |
| Older releases | ❌ — please update first and re-test |

## Reporting a Vulnerability

**Do not open a public issue for security problems.**

Use one of these private channels instead:

1. **GitHub Private Vulnerability Reporting** (preferred): go to the **Security** tab of this repository and click *"Report a vulnerability"*. No account setup or email needed.
2. **Security advisories**: maintainers can also be reached via a GitHub Security Advisory on this repo.

Please include:

- Brushot version / commit SHA, macOS version and architecture
- Step-by-step reproduction
- Impact assessment, especially if it involves captured screen content, recorded audio, or the pin library on disk
- (Optional) Suggested fix or PoC

### What to expect

- Acknowledgement within 7 days
- Assessment and a fix timeline based on severity
- Credit in the release notes if you wish

## Scope Notes

These areas are considered security-relevant:

- Anything that leaks captured pixels, OCR text, recordings, or the pin library outside the user's intent
- Permission handling that grants capture without the proper macOS TCC consent
- Watermark or export paths that write outside the configured output location
- Crashes triggered by crafted clipboard content pasted into `Pin from Clipboard`

Out of scope: bugs that require the attacker to already control the user's session.
