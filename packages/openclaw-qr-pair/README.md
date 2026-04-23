# openclaw-qr-pair

Host-side helper for OpenClaw mobile onboarding.

## What it does

- Prefers a Tailscale IPv4 address when building a gateway URL.
- Uses `openclaw qr --json` to generate the actual setup code.
- Renders the setup code as a terminal QR.
- Watches `openclaw devices list --json` for either:
  - a new paired `node` device created by silent bootstrap handoff, or
  - a new pending `node` request that still needs approval.
- Approves exactly one fallback pending request when necessary, then exits.

## Current limits

- It wraps the public `openclaw` CLI instead of speaking the Gateway protocol directly.
- It does not yet correlate pending requests to the bootstrap token itself; it uses a conservative "single new node request after helper start" rule.
- Upstream docs currently warn that Tailscale/public `ws://` mobile pairing fails closed. Treat raw tailnet-IP pairing as an active validation item, not settled behavior.
