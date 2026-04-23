# openclaw-qr-pair

Host-side helper for OpenClaw mobile onboarding.

## What it does

- Uses OpenClaw remote configuration when run with `--remote`.
- Otherwise prefers a private LAN IPv4 address when building a local `ws://` gateway URL.
- Uses `openclaw qr --json` to generate the actual setup code.
- Renders the setup code as a terminal QR.
- Watches `openclaw devices list --json` for either:
  - a new paired `node` device created by silent bootstrap handoff, or
  - a new pending `node` request that still needs approval.
- Approves exactly one fallback pending request when necessary, then exits.

## Current limits

- It wraps the public `openclaw` CLI instead of speaking the Gateway protocol directly.
- It does not yet correlate pending requests to the bootstrap token itself; it uses a conservative "single new node request after helper start" rule.
- Upstream OpenClaw fails closed for Tailscale/public `ws://` mobile pairing. Use `--remote` with Tailscale Serve/Funnel or pass an explicit `wss://` URL.

## Remote pairing

For iPhone pairing over Tailscale, use OpenClaw's secure remote path:

```bash
openclaw gateway --tailscale serve
node src/cli.js --verbose --remote
```

`--remote` calls `openclaw qr --remote`, which prefers `gateway.remote.url` and can also use `gateway.tailscale.mode=serve|funnel`. This should produce a `wss://` setup URL instead of a raw `ws://100.x.x.x` URL.

## Debugging pairing failures

Run with verbose diagnostics when the iPhone reports that it could not connect to the server:

```bash
node src/cli.js --verbose
```

Verbose mode writes diagnostic logs to stderr while keeping the QR in the terminal. It reports:

- which Gateway URL was encoded in the QR,
- whether the helper selected a Tailscale, LAN, or explicit address,
- the baseline and polled `openclaw devices list --json` counts,
- whether a new pending or paired `node` device appeared,
- whether `openclaw devices approve` was attempted and completed.

If no new pending request appears before timeout, the phone likely never reached the Gateway URL. In that case, retry with an address the phone can reach:

```bash
node src/cli.js --verbose --url ws://<reachable-host>:18789
```

For Tailscale or public routes, use a secure URL:

```bash
node src/cli.js --verbose --remote
node src/cli.js --verbose --url wss://<gateway-host>/ws
```
