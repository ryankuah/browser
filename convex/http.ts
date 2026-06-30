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

    try {
      await ctx.runAction(api.google.completeOAuth, { code, state });
      return redirectToBrowserOAuthCallback("success");
    } catch (error) {
      const message = error instanceof Error ? error.message : "Google OAuth failed.";
      return redirectToBrowserOAuthCallback("error", message);
    }
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

function redirectToBrowserOAuthCallback(status: "success" | "error", message?: string) {
  const callbackUrl = new URL("com.ryankuah.browser://google/oauth/callback");
  callbackUrl.searchParams.set("status", status);
  if (message) {
    callbackUrl.searchParams.set("message", message);
  }
  const escapedCallbackUrl = escapeHTML(callbackUrl.toString());
  const title = status === "success" ? "Google account connected" : "Google connection failed";
  const body =
    status === "success"
      ? "Google account connected. Returning to Browser."
      : "Google connection failed. Returning to Browser.";

  return new Response(
    `<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <title>${title}</title>
    <meta http-equiv="refresh" content="0; url=${escapedCallbackUrl}">
  </head>
  <body>
    <p>${body}</p>
    <script>window.location.href = ${JSON.stringify(callbackUrl.toString())};</script>
    <p><a href="${escapedCallbackUrl}">Return to Browser</a></p>
  </body>
</html>`,
    {
      status: 200,
      headers: { "content-type": "text/html; charset=utf-8" },
    },
  );
}

function escapeHTML(value: string) {
  return value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

export default http;
