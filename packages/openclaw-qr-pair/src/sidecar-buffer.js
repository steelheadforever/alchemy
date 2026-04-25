const BUFFERED_EVENT_TYPES = new Set([
  "session.message",
  "agent",
  "chat",
  "session.tool",
  "exec.approval.requested",
  "exec.approval.resolved",
  "plugin.approval.requested",
  "plugin.approval.resolved",
]);

export function EventBuffer({
  maxEventsPerChannel = 1000,
  maxAgeMs = 24 * 60 * 60 * 1000,
} = {}) {
  const channels = new Map();

  function extractSessionKey(frame) {
    const payload = frame?.payload;
    if (!payload) return null;
    return (
      payload.sessionKey ??
      payload.key ??
      payload.session?.key ??
      payload.request?.sessionKey ??
      null
    );
  }

  function shouldBuffer(frame) {
    const eventName = frame?.event;
    return typeof eventName === "string" && BUFFERED_EVENT_TYPES.has(eventName);
  }

  function push(rawFrame) {
    if (!shouldBuffer(rawFrame)) return false;

    const sessionKey = extractSessionKey(rawFrame);
    if (!sessionKey) return false;

    if (!channels.has(sessionKey)) {
      channels.set(sessionKey, []);
    }

    const bucket = channels.get(sessionKey);
    bucket.push({ frame: rawFrame, timestamp: Date.now() });

    // Trim oldest if over cap.
    while (bucket.length > maxEventsPerChannel) {
      bucket.shift();
    }

    return true;
  }

  function evict() {
    const cutoff = Date.now() - maxAgeMs;
    for (const [key, bucket] of channels) {
      const fresh = bucket.filter((entry) => entry.timestamp >= cutoff);
      if (fresh.length === 0) {
        channels.delete(key);
      } else {
        channels.set(key, fresh);
      }
    }
  }

  function peek(sessionKey) {
    evict();
    const bucket = channels.get(sessionKey);
    if (!bucket) return [];
    return bucket.map((entry) => entry.frame);
  }

  function peekAll() {
    evict();
    const all = [];
    for (const bucket of channels.values()) {
      for (const entry of bucket) {
        all.push(entry.frame);
      }
    }
    return all;
  }

  function drain(sessionKey) {
    const events = peek(sessionKey);
    channels.delete(sessionKey);
    return events;
  }

  function stats() {
    let totalEvents = 0;
    for (const bucket of channels.values()) {
      totalEvents += bucket.length;
    }
    return {
      channels: channels.size,
      totalEvents,
    };
  }

  return { push, peek, peekAll, drain, stats, extractSessionKey, shouldBuffer };
}
