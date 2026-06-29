import { httpRouter } from "convex/server";
import { httpAction } from "./_generated/server";
import { api, internal } from "./_generated/api";

const http = httpRouter();

http.route({
  path: "/api/google/oauth/callback",
  method: "GET",
  handler: httpAction(async (ctx, request) => {
    const url = new URL(request.url);
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    if (!code || !state) {
      return new Response("Missing Google OAuth code or state.", { status: 400 });
    }

    await ctx.runAction(api.google.completeOAuth, { code, state });
    return new Response("Google account connected. You can return to Browser.", {
      status: 200,
      headers: { "content-type": "text/plain" },
    });
  }),
});

http.route({
  path: "/api/google/pubsub/gmail",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const payload = await request.json().catch(() => null);
    const rawData = payload?.message?.data;
    const decoded = typeof rawData === "string" ? decodePubSubData(rawData) : {};
    await ctx.runMutation(internal.google.enqueueSyncJob, {
      provider: "gmail",
      reason: "pubsub",
      payloadJson: JSON.stringify(decoded),
    });
    return new Response(null, { status: 204 });
  }),
});

http.route({
  path: "/api/google/calendar/watch",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const resourceState = request.headers.get("x-goog-resource-state") ?? "unknown";
    const channelId = request.headers.get("x-goog-channel-id") ?? undefined;
    const resourceId = request.headers.get("x-goog-resource-id") ?? undefined;
    await ctx.runMutation(internal.google.enqueueSyncJob, {
      provider: "calendar",
      reason: "watch",
      payloadJson: JSON.stringify({ resourceState, channelId, resourceId }),
    });
    return new Response(null, { status: 204 });
  }),
});

function decodePubSubData(value: string) {
  try {
    return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(value), (char) => char.charCodeAt(0))));
  } catch {
    return {};
  }
}

export default http;
