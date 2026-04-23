# Upstream Alignment

Verified against OpenClaw docs on April 22, 2026.

## Confirmed upstream behavior

- `openclaw qr` already exists and generates a mobile setup QR from Gateway configuration.
- The setup code payload is currently a base64-encoded JSON object with `url` and `bootstrapToken`.
- Device pairing approval is handled through `openclaw devices list` and `openclaw devices approve`.
- The Gateway protocol returns issued device tokens in `hello-ok.auth.deviceToken` after a successful connect.

## Important draft-spec deltas

- The draft spec proposes a custom QR payload with `v`, `addr`, `fp`, `secret`, `exp`, and `name`.
- Current upstream docs do not describe that payload. They describe `url` + `bootstrapToken`.
- The draft spec assumes direct Tailscale `ws://tailnet-ip:18789` mobile pairing.
- Current upstream `openclaw qr` docs state that mobile pairing fails closed for Tailscale or public `ws://` URLs and recommend `wss://` / Serve-style ingress instead.

## Immediate implication

The repo now implements the verified setup-code contract first. If we still want a Tailscale-native raw-WS pairing flow, we should treat that as a deliberate divergence and validate it against the real Gateway behavior before we harden the iOS transport around it.

## Source URLs

- `https://docs.openclaw.ai/cli/qr`
- `https://docs.openclaw.ai/channels/pairing`
- `https://docs.openclaw.ai/gateway/protocol`

