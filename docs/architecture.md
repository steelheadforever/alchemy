# Architecture

Alchemy is split into two workstreams:

## `packages/openclaw-qr-pair`

Host-side CLI helper for local onboarding.

- Uses the installed `openclaw` CLI as the integration surface.
- Generates setup codes through `openclaw qr --json`.
- Polls `openclaw devices list --json` and approves a single new pending `node` request.
- Prefers a Tailscale IPv4 address when available, with LAN fallback.

## `apps/ios`

Swift package containing the first iOS-side contract and onboarding shell.

- Parses the OpenClaw setup code payload.
- Separates bootstrap parsing from eventual transport code.
- Exposes a small SwiftUI onboarding view so the payload contract is executable in code now instead of staying in prose.

## Why this shape

The repo started empty. The highest-leverage first slice is the shared onboarding contract and the host helper wrapper around the existing OpenClaw pairing flow. That gives both workstreams a stable seam before we build the full chat client and WebSocket runtime.

