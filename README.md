# Alchemy

Native iOS client and host-side pairing helper for OpenClaw.

As of April 22, 2026, upstream OpenClaw already ships `openclaw qr` and `openclaw devices`. This repo treats those as the current source of truth for bootstrap pairing instead of inventing a parallel handshake immediately.

## Layout

- `packages/openclaw-qr-pair`: Node.js helper that wraps `openclaw qr` and auto-approves the next matching device request.
- `apps/ios`: Swift package holding the iOS onboarding contract, parsing, and initial SwiftUI shell.
- `docs`: architecture notes and upstream-alignment findings.

## Quick Start

Helper package:

```bash
cd packages/openclaw-qr-pair
npm install
npm test
node src/cli.js
```

iOS package:

```bash
cd apps/ios
swift test
```

## Notes

- The current helper uses upstream OpenClaw setup codes: base64/base64url JSON containing `url` and `bootstrapToken`.
- The current auto-approval path is intentionally conservative: it only approves a single new pending `node` pairing request observed after the helper starts.
- The draft spec assumed a custom QR payload with `addr`, `fp`, `secret`, and `exp`. That is not what current upstream OpenClaw emits today, so the repo documents that delta explicitly before we lock in app-side behavior.

## License

[MIT](LICENSE)

