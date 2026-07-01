import { v } from "convex/values";
import { ActionCtx, action, internalAction, internalMutation, internalQuery, mutation, query } from "./_generated/server";
import { api, internal } from "./_generated/api";
import { Id } from "./_generated/dataModel";
import { getCurrentUser } from "./users";

const GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.readonly";
const CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar.readonly";
const GOOGLE_SCOPES = [GMAIL_SCOPE, CALENDAR_SCOPE, "openid", "email", "profile"].join(" ");
const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
const GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const GMAIL_BASE_URL = "https://gmail.googleapis.com/gmail/v1/users/me";
const CALENDAR_BASE_URL = "https://www.googleapis.com/calendar/v3";
const DEFAULT_GMAIL_BACKFILL_QUERY = "newer_than:365d";
// Backfills run uncapped by default (until Gmail stops returning a nextPageToken).
// This only bounds an explicit maxPageCount override, e.g. via resumeGmailBackfill.
const MAX_GMAIL_BACKFILL_MAX_PAGES = 2000;
const GMAIL_BACKFILL_PAGE_SIZE = 100;
const GMAIL_BACKFILL_FETCH_CONCURRENCY = 10;

export const connectedAccounts = query({
  args: { sessionToken: v.string() },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    return await ctx.db.query("googleAccounts").withIndex("by_user", (q) => q.eq("userId", userId)).collect();
  },
});

export const startOAuth = mutation({
  args: { sessionToken: v.string() },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const state = crypto.randomUUID();
    const now = Date.now();
    await ctx.db.insert("oauthStates", {
      userId,
      state,
      createdAt: now,
      expiresAt: now + 10 * 60 * 1000,
    });

    const url = new URL(GOOGLE_AUTH_URL);
    url.searchParams.set("client_id", requireEnv("GOOGLE_CLIENT_ID"));
    url.searchParams.set("redirect_uri", requireEnv("GOOGLE_OAUTH_REDIRECT_URI"));
    url.searchParams.set("response_type", "code");
    url.searchParams.set("scope", GOOGLE_SCOPES);
    url.searchParams.set("access_type", "offline");
    url.searchParams.set("prompt", "consent");
    url.searchParams.set("state", state);

    return { authorizationUrl: url.toString() };
  },
});

export const completeOAuth = action({
  args: {
    code: v.string(),
    state: v.string(),
  },
  handler: async (ctx, args) => {
    const state = await ctx.runMutation(internal.google.consumeOAuthState, { state: args.state });
    const tokens = await exchangeAuthorizationCode(args.code);
    const accessToken = tokens.access_token;
    if (!accessToken || !tokens.refresh_token) {
      throw new Error("Google did not return the required tokens.");
    }

    const profile = await googleJson<{ sub?: string; email?: string; name?: string }>(
      "https://openidconnect.googleapis.com/v1/userinfo",
      accessToken,
    );
    if (!profile.email) {
      throw new Error("Google account did not return an email address.");
    }

    const now = Date.now();
    const encryptedRefreshToken = await encryptToken(tokens.refresh_token);
    const encryptedAccessToken = await encryptToken(accessToken);
    const googleAccountId: Id<"googleAccounts"> = await ctx.runMutation(internal.google.upsertGoogleAccount, {
      userId: state.userId,
      googleSubject: profile.sub,
      email: profile.email,
      displayName: profile.name,
      scope: tokens.scope ?? GOOGLE_SCOPES,
      encryptedRefreshToken,
      encryptedAccessToken,
      accessTokenExpiresAt: now + (tokens.expires_in ?? 3600) * 1000,
    });

    await ctx.runAction(internal.google.initialGoogleImport, { googleAccountId });

    return { ok: true, email: profile.email };
  },
});

export const setCalendarSelected = mutation({
  args: {
    sessionToken: v.string(),
    calendarId: v.id("googleCalendars"),
    selected: v.boolean(),
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const calendar = await ctx.db.get(args.calendarId);
    if (!calendar || calendar.userId !== userId) {
      throw new Error("Calendar not found.");
    }
    await ctx.db.patch(args.calendarId, { selected: args.selected, updatedAt: Date.now() });
  },
});

export const consumeOAuthState = internalMutation({
  args: { state: v.string() },
  handler: async (ctx, args) => {
    const state = await ctx.db
      .query("oauthStates")
      .withIndex("by_state", (q) => q.eq("state", args.state))
      .unique();
    if (!state || state.expiresAt < Date.now()) {
      throw new Error("Invalid or expired Google OAuth state.");
    }
    await ctx.db.delete(state._id);
    return { userId: state.userId };
  },
});

export const upsertGoogleAccount = internalMutation({
  args: {
    userId: v.id("users"),
    googleSubject: v.optional(v.string()),
    email: v.string(),
    displayName: v.optional(v.string()),
    scope: v.string(),
    encryptedRefreshToken: v.string(),
    encryptedAccessToken: v.string(),
    accessTokenExpiresAt: v.number(),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const existing = await ctx.db
      .query("googleAccounts")
      .withIndex("by_user_email", (q) => q.eq("userId", args.userId).eq("email", args.email))
      .unique();

    if (existing) {
      await ctx.db.patch(existing._id, { ...args, updatedAt: now });
      return existing._id;
    }

    return await ctx.db.insert("googleAccounts", { ...args, createdAt: now, updatedAt: now });
  },
});

export const initialGoogleImport = internalAction({
  args: { googleAccountId: v.id("googleAccounts") },
  handler: async (ctx, args) => {
    await ctx.runAction(internal.google.syncGmail, { googleAccountId: args.googleAccountId, historyId: undefined });
    const account = await ctx.runQuery(api.mail.googleAccountForSync, { googleAccountId: args.googleAccountId });
    await ctx.runMutation(internal.google.startGmailBackfillForAccount, {
      googleAccountId: args.googleAccountId,
      userId: account.userId,
      query: DEFAULT_GMAIL_BACKFILL_QUERY,
      reset: false,
    });
    await ctx.runAction(internal.google.syncCalendars, { googleAccountId: args.googleAccountId });
  },
});

export const syncGmail = internalAction({
  args: {
    googleAccountId: v.id("googleAccounts"),
    historyId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const account = await ctx.runQuery(api.mail.googleAccountForSync, { googleAccountId: args.googleAccountId });
    const accessToken = await validAccessToken(ctx, account);

    const listUrl = args.historyId
      ? `${GMAIL_BASE_URL}/history?startHistoryId=${encodeURIComponent(args.historyId)}&historyTypes=messageAdded`
      : `${GMAIL_BASE_URL}/messages?maxResults=25`;
    const list = await googleJson<GmailListResponse | GmailHistoryResponse>(listUrl, accessToken);
    const messageIds = gmailMessageIds(list);

    for (const messageId of messageIds) {
      await importGmailMessage(ctx, account.userId, args.googleAccountId, messageId, accessToken, true);
    }

    const latestHistoryId = "historyId" in list ? list.historyId : undefined;
    await ctx.runMutation(internal.google.saveGmailSyncState, {
      googleAccountId: args.googleAccountId,
      historyId: latestHistoryId,
    });
  },
});

export const syncGmailBackfillPage = internalAction({
  args: {
    googleAccountId: v.id("googleAccounts"),
  },
  handler: async (ctx, args) => {
    const state = await ctx.runMutation(internal.google.takeGmailBackfillPage, {
      googleAccountId: args.googleAccountId,
    });
    if (!state) {
      return;
    }

    try {
      const account = await ctx.runQuery(api.mail.googleAccountForSync, { googleAccountId: args.googleAccountId });
      const accessToken = await validAccessToken(ctx, account);
      const url = new URL(`${GMAIL_BASE_URL}/messages`);
      url.searchParams.set("maxResults", String(GMAIL_BACKFILL_PAGE_SIZE));
      if (state.backfillQuery) {
        url.searchParams.set("q", state.backfillQuery);
      }
      if (state.backfillPageToken) {
        url.searchParams.set("pageToken", state.backfillPageToken);
      }

      const list = await googleJson<GmailListResponse>(url.toString(), accessToken);
      const messageIds = (list.messages ?? []).map((message) => message.id).filter(Boolean);
      for (let i = 0; i < messageIds.length; i += GMAIL_BACKFILL_FETCH_CONCURRENCY) {
        const batch = messageIds.slice(i, i + GMAIL_BACKFILL_FETCH_CONCURRENCY);
        await Promise.all(
          batch.map((messageId) =>
            importGmailMessage(ctx, account.userId, args.googleAccountId, messageId, accessToken, false),
          ),
        );
      }
      const importedCount = messageIds.length;

      await ctx.runMutation(internal.google.finishGmailBackfillPage, {
        googleAccountId: args.googleAccountId,
        nextPageToken: list.nextPageToken,
        resultSizeEstimate: list.resultSizeEstimate,
        scannedCount: messageIds.length,
        importedCount,
      });
    } catch (error) {
      await ctx.runMutation(internal.google.failGmailBackfill, {
        googleAccountId: args.googleAccountId,
        error: error instanceof Error ? error.message : String(error),
      });
      throw error;
    }
  },
});

export const syncCalendars = internalAction({
  args: { googleAccountId: v.id("googleAccounts") },
  handler: async (ctx, args) => {
    const account = await ctx.runQuery(api.mail.googleAccountForSync, { googleAccountId: args.googleAccountId });
    const accessToken = await validAccessToken(ctx, account);
    const calendarList = await googleJson<{ items?: GoogleCalendar[] }>(
      `${CALENDAR_BASE_URL}/users/me/calendarList`,
      accessToken,
    );

    for (const calendar of calendarList.items ?? []) {
      const calendarId = await ctx.runMutation(internal.google.upsertCalendar, {
        googleAccountId: args.googleAccountId,
        userId: account.userId,
        calendar,
      });
      if (calendar.primary) {
        await syncCalendarEvents(ctx, account.userId, args.googleAccountId, calendar.id, accessToken);
      } else {
        const stored = await ctx.runQuery(api.calendar.calendarById, { calendarId });
        if (stored?.selected) {
          await syncCalendarEvents(ctx, account.userId, args.googleAccountId, calendar.id, accessToken);
        }
      }
    }
  },
});

export const upsertGmailMessage = internalMutation({
  args: {
    userId: v.id("users"),
    googleAccountId: v.id("googleAccounts"),
    message: v.object({
      id: v.string(),
      threadId: v.string(),
      historyId: v.optional(v.string()),
      labelIds: v.array(v.string()),
      from: v.optional(v.string()),
      to: v.optional(v.string()),
      cc: v.optional(v.string()),
      subject: v.optional(v.string()),
      date: v.optional(v.number()),
      snippet: v.optional(v.string()),
      bodyText: v.optional(v.string()),
      bodyHtml: v.optional(v.string()),
      internalDate: v.optional(v.number()),
      attachments: v.array(v.any()),
    }),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const thread = await ctx.db
      .query("gmailThreads")
      .withIndex("by_account_thread", (q) =>
        q.eq("googleAccountId", args.googleAccountId).eq("providerThreadId", args.message.threadId),
      )
      .unique();
    if (thread) {
      await ctx.db.patch(thread._id, {
        snippet: args.message.snippet,
        historyId: args.message.historyId,
        updatedAt: now,
      });
    } else {
      await ctx.db.insert("gmailThreads", {
        userId: args.userId,
        googleAccountId: args.googleAccountId,
        providerThreadId: args.message.threadId,
        snippet: args.message.snippet,
        historyId: args.message.historyId,
        updatedAt: now,
      });
    }

    const existing = await ctx.db
      .query("gmailMessages")
      .withIndex("by_account_message", (q) =>
        q.eq("googleAccountId", args.googleAccountId).eq("providerMessageId", args.message.id),
      )
      .unique();
    const row = {
      userId: args.userId,
      googleAccountId: args.googleAccountId,
      providerMessageId: args.message.id,
      providerThreadId: args.message.threadId,
      historyId: args.message.historyId,
      labelIds: args.message.labelIds,
      from: args.message.from,
      to: args.message.to,
      cc: args.message.cc,
      subject: args.message.subject,
      date: args.message.date,
      snippet: args.message.snippet,
      bodyText: args.message.bodyText,
      bodyHtml: args.message.bodyHtml,
      internalDate: args.message.internalDate,
      importedAt: now,
      updatedAt: now,
    };
    const gmailMessageId = existing?._id ?? (await ctx.db.insert("gmailMessages", row));
    if (existing) {
      await ctx.db.patch(existing._id, row);
    }

    await ctx.scheduler.runAfter(0, internal.mailAnalysis.analyzeGmailMessage, { gmailMessageId });
  },
});

export const upsertGmailAttachment = internalMutation({
  args: {
    userId: v.id("users"),
    googleAccountId: v.id("googleAccounts"),
    providerMessageId: v.string(),
    attachmentId: v.string(),
    filename: v.string(),
    mimeType: v.string(),
    size: v.number(),
    storageId: v.id("_storage"),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("gmailAttachments")
      .withIndex("by_message", (q) =>
        q.eq("googleAccountId", args.googleAccountId).eq("providerMessageId", args.providerMessageId),
      )
      .filter((q) => q.eq(q.field("attachmentId"), args.attachmentId))
      .unique();
    if (existing) {
      await ctx.db.patch(existing._id, { storageId: args.storageId, size: args.size, importedAt: Date.now() });
    } else {
      await ctx.db.insert("gmailAttachments", { ...args, importedAt: Date.now() });
    }
  },
});

export const saveGmailSyncState = internalMutation({
  args: {
    googleAccountId: v.id("googleAccounts"),
    historyId: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("gmailSyncState")
      .withIndex("by_account", (q) => q.eq("googleAccountId", args.googleAccountId))
      .unique();
    if (existing) {
      await ctx.db.patch(existing._id, { historyId: args.historyId ?? existing.historyId, updatedAt: Date.now() });
    } else {
      await ctx.db.insert("gmailSyncState", { ...args, updatedAt: Date.now() });
    }
  },
});

export const startGmailBackfillForAccount = internalMutation({
  args: {
    userId: v.id("users"),
    googleAccountId: v.id("googleAccounts"),
    query: v.optional(v.string()),
    maxPageCount: v.optional(v.number()),
    reset: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const account = await ctx.db.get(args.googleAccountId);
    if (!account || account.userId !== args.userId) {
      throw new Error("Google account not found.");
    }

    const now = Date.now();
    const query = normalizeBackfillQuery(args.query);
    const maxPageCount = normalizeBackfillMaxPageCount(args.maxPageCount);
    const existing = await ctx.db
      .query("gmailSyncState")
      .withIndex("by_account", (q) => q.eq("googleAccountId", args.googleAccountId))
      .unique();

    if (existing && !args.reset) {
      // The one-time setup backfill already ran (or is running) for this account.
      // Never silently re-run the full historical import.
      return {
        googleAccountId: args.googleAccountId,
        status: existing.backfillStatus ?? "done",
        query: existing.backfillQuery ?? query,
        maxPageCount: existing.backfillMaxPageCount ?? maxPageCount,
      };
    }

    const pageToken = args.reset ? undefined : existing?.backfillPageToken;

    const patch = {
      backfillStatus: "queued",
      backfillQuery: query,
      backfillPageToken: pageToken,
      backfillPageCount: args.reset ? 0 : existing?.backfillPageCount ?? 0,
      backfillMaxPageCount: maxPageCount,
      backfillImportedCount: args.reset ? 0 : existing?.backfillImportedCount ?? 0,
      backfillScannedCount: args.reset ? 0 : existing?.backfillScannedCount ?? 0,
      backfillResultSizeEstimate: existing?.backfillResultSizeEstimate,
      backfillRequestedAt: now,
      backfillStartedAt: args.reset ? undefined : existing?.backfillStartedAt,
      backfillCompletedAt: undefined,
      backfillLastError: undefined,
      updatedAt: now,
    };

    if (existing) {
      await ctx.db.patch(existing._id, patch);
    } else {
      await ctx.db.insert("gmailSyncState", {
        googleAccountId: args.googleAccountId,
        ...patch,
      });
    }

    await ctx.scheduler.runAfter(0, internal.google.syncGmailBackfillPage, {
      googleAccountId: args.googleAccountId,
    });

    return { googleAccountId: args.googleAccountId, status: "queued", query, maxPageCount };
  },
});

// Continues a backfill that previously stopped after hitting its page cap,
// resuming from the preserved page token instead of starting over. For
// ops use only (e.g. `npx convex run google:resumeGmailBackfill ...`) —
// not exposed to clients.
export const resumeGmailBackfill = internalMutation({
  args: {
    googleAccountId: v.id("googleAccounts"),
    maxPageCount: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("gmailSyncState")
      .withIndex("by_account", (q) => q.eq("googleAccountId", args.googleAccountId))
      .unique();
    if (!existing) {
      throw new Error("No backfill state found for this account.");
    }
    if (existing.backfillStatus === "queued" || existing.backfillStatus === "running") {
      return {
        status: existing.backfillStatus,
        pageCount: existing.backfillPageCount,
        maxPageCount: existing.backfillMaxPageCount,
      };
    }

    const maxPageCount = normalizeBackfillMaxPageCount(args.maxPageCount ?? existing.backfillMaxPageCount);
    await ctx.db.patch(existing._id, {
      backfillStatus: "queued",
      backfillMaxPageCount: maxPageCount,
      backfillCompletedAt: undefined,
      backfillLastError: undefined,
      updatedAt: Date.now(),
    });

    await ctx.scheduler.runAfter(0, internal.google.syncGmailBackfillPage, {
      googleAccountId: args.googleAccountId,
    });

    return {
      status: "queued",
      pageCount: existing.backfillPageCount,
      maxPageCount,
      pageToken: existing.backfillPageToken,
    };
  },
});

export const takeGmailBackfillPage = internalMutation({
  args: {
    googleAccountId: v.id("googleAccounts"),
  },
  handler: async (ctx, args) => {
    const state = await ctx.db
      .query("gmailSyncState")
      .withIndex("by_account", (q) => q.eq("googleAccountId", args.googleAccountId))
      .unique();
    if (!state || (state.backfillStatus !== "queued" && state.backfillStatus !== "running")) {
      return null;
    }
    if (state.backfillMaxPageCount !== undefined && (state.backfillPageCount ?? 0) >= state.backfillMaxPageCount) {
      await ctx.db.patch(state._id, {
        backfillStatus: "done",
        backfillCompletedAt: Date.now(),
        updatedAt: Date.now(),
      });
      return null;
    }

    const now = Date.now();
    await ctx.db.patch(state._id, {
      backfillStatus: "running",
      backfillStartedAt: state.backfillStartedAt ?? now,
      backfillLastError: undefined,
      updatedAt: now,
    });
    return state;
  },
});

export const finishGmailBackfillPage = internalMutation({
  args: {
    googleAccountId: v.id("googleAccounts"),
    nextPageToken: v.optional(v.string()),
    resultSizeEstimate: v.optional(v.number()),
    scannedCount: v.number(),
    importedCount: v.number(),
  },
  handler: async (ctx, args) => {
    const state = await ctx.db
      .query("gmailSyncState")
      .withIndex("by_account", (q) => q.eq("googleAccountId", args.googleAccountId))
      .unique();
    if (!state) {
      return;
    }

    const now = Date.now();
    const pageCount = (state.backfillPageCount ?? 0) + 1;
    const maxPageCount = state.backfillMaxPageCount;
    const shouldContinue = Boolean(args.nextPageToken) && (maxPageCount === undefined || pageCount < maxPageCount);
    await ctx.db.patch(state._id, {
      backfillStatus: shouldContinue ? "queued" : "done",
      backfillPageToken: args.nextPageToken,
      backfillPageCount: pageCount,
      backfillImportedCount: (state.backfillImportedCount ?? 0) + args.importedCount,
      backfillScannedCount: (state.backfillScannedCount ?? 0) + args.scannedCount,
      backfillResultSizeEstimate: args.resultSizeEstimate ?? state.backfillResultSizeEstimate,
      backfillCompletedAt: shouldContinue ? undefined : now,
      backfillLastError: undefined,
      updatedAt: now,
    });

    if (shouldContinue) {
      await ctx.scheduler.runAfter(0, internal.google.syncGmailBackfillPage, {
        googleAccountId: args.googleAccountId,
      });
    }
  },
});

export const failGmailBackfill = internalMutation({
  args: {
    googleAccountId: v.id("googleAccounts"),
    error: v.string(),
  },
  handler: async (ctx, args) => {
    const state = await ctx.db
      .query("gmailSyncState")
      .withIndex("by_account", (q) => q.eq("googleAccountId", args.googleAccountId))
      .unique();
    if (state) {
      await ctx.db.patch(state._id, {
        backfillStatus: "failed",
        backfillLastError: args.error,
        updatedAt: Date.now(),
      });
    }
  },
});

export const upsertCalendar = internalMutation({
  args: {
    userId: v.id("users"),
    googleAccountId: v.id("googleAccounts"),
    calendar: v.any(),
  },
  handler: async (ctx, args) => {
    const now = Date.now();
    const calendar = args.calendar as GoogleCalendar;
    const existing = await ctx.db
      .query("googleCalendars")
      .withIndex("by_account_calendar", (q) =>
        q.eq("googleAccountId", args.googleAccountId).eq("providerCalendarId", calendar.id),
      )
      .unique();
    const row = {
      userId: args.userId,
      googleAccountId: args.googleAccountId,
      providerCalendarId: calendar.id,
      summary: calendar.summary ?? "Calendar",
      description: calendar.description,
      timeZone: calendar.timeZone,
      primary: calendar.primary === true,
      selected: existing?.selected ?? calendar.primary === true,
      updatedAt: now,
    };
    if (existing) {
      await ctx.db.patch(existing._id, row);
      return existing._id;
    }
    return await ctx.db.insert("googleCalendars", row);
  },
});

export const upsertCalendarEvent = internalMutation({
  args: {
    userId: v.id("users"),
    googleAccountId: v.id("googleAccounts"),
    providerCalendarId: v.string(),
    event: v.any(),
  },
  handler: async (ctx, args) => {
    const event = args.event as GoogleCalendarEvent;
    const start = parseGoogleEventDate(event.start);
    const end = parseGoogleEventDate(event.end);
    const row = {
      userId: args.userId,
      googleAccountId: args.googleAccountId,
      providerCalendarId: args.providerCalendarId,
      providerEventId: event.id,
      status: event.status ?? "confirmed",
      summary: event.summary,
      description: event.description,
      location: event.location,
      htmlLink: event.htmlLink,
      startText: event.start?.dateTime ?? event.start?.date,
      endText: event.end?.dateTime ?? event.end?.date,
      startTimestamp: start,
      endTimestamp: end,
      attendeesJson: event.attendees ? JSON.stringify(event.attendees) : undefined,
      updatedAt: Date.now(),
    };
    const existing = await ctx.db
      .query("googleCalendarEvents")
      .withIndex("by_calendar_event", (q) =>
        q
          .eq("googleAccountId", args.googleAccountId)
          .eq("providerCalendarId", args.providerCalendarId)
          .eq("providerEventId", event.id),
      )
      .unique();
    if (existing) {
      await ctx.db.patch(existing._id, row);
    } else {
      await ctx.db.insert("googleCalendarEvents", row);
    }
  },
});

export const refreshAccessToken = internalMutation({
  args: {
    googleAccountId: v.id("googleAccounts"),
    encryptedAccessToken: v.string(),
    accessTokenExpiresAt: v.number(),
  },
  handler: async (ctx, args) => {
    await ctx.db.patch(args.googleAccountId, {
      encryptedAccessToken: args.encryptedAccessToken,
      accessTokenExpiresAt: args.accessTokenExpiresAt,
      updatedAt: Date.now(),
    });
  },
});

export const resolveGoogleAccountByEmail = internalQuery({
  args: {
    email: v.string(),
  },
  handler: async (ctx, args) => {
    const matches = await ctx.db
      .query("googleAccounts")
      .filter((q) => q.eq(q.field("email"), args.email))
      .take(2);
    return matches.length === 1 ? matches[0]._id : undefined;
  },
});

export const resolveGoogleAccountByCalendarChannel = internalQuery({
  args: {
    channelId: v.string(),
  },
  handler: async (ctx, args) => {
    const calendar = await ctx.db
      .query("googleCalendars")
      .withIndex("by_channel_id", (q) => q.eq("channelId", args.channelId))
      .unique();
    return calendar?.googleAccountId;
  },
});

async function validAccessToken(ctx: ActionCtx, account: GoogleAccountForSync) {
  if (account.encryptedAccessToken && account.accessTokenExpiresAt && account.accessTokenExpiresAt > Date.now() + 60_000) {
    return await decryptToken(account.encryptedAccessToken);
  }
  if (!account.encryptedRefreshToken) {
    throw new Error("Google account is missing a refresh token.");
  }

  const refreshToken = await decryptToken(account.encryptedRefreshToken);
  const refreshed = await refreshGoogleAccessToken(refreshToken);
  const encryptedAccessToken = await encryptToken(refreshed.access_token);
  await ctx.runMutation(internal.google.refreshAccessToken, {
    googleAccountId: account._id,
    encryptedAccessToken,
    accessTokenExpiresAt: Date.now() + (refreshed.expires_in ?? 3600) * 1000,
  });
  return refreshed.access_token;
}

async function importGmailMessage(
  ctx: ActionCtx,
  userId: Id<"users">,
  googleAccountId: Id<"googleAccounts">,
  messageId: string,
  accessToken: string,
  importAttachments: boolean,
) {
  const message = await googleJson<GmailMessage>(
    `${GMAIL_BASE_URL}/messages/${encodeURIComponent(messageId)}?format=full`,
    accessToken,
  );
  const parsed = parseGmailMessage(message);
  await ctx.runMutation(internal.google.upsertGmailMessage, {
    googleAccountId,
    userId,
    message: parsed,
  });

  if (!importAttachments) {
    return;
  }

  for (const attachment of parsed.attachments) {
    const attachmentResponse = await googleJson<{ data?: string; size?: number }>(
      `${GMAIL_BASE_URL}/messages/${encodeURIComponent(message.id)}/attachments/${encodeURIComponent(
        attachment.attachmentId,
      )}`,
      accessToken,
    );
    const bytes = base64UrlToBytes(attachmentResponse.data ?? "");
    const storageId = await ctx.storage.store(new Blob([bytes], { type: attachment.mimeType }));
    await ctx.runMutation(internal.google.upsertGmailAttachment, {
      googleAccountId,
      userId,
      providerMessageId: message.id,
      attachmentId: attachment.attachmentId,
      filename: attachment.filename,
      mimeType: attachment.mimeType,
      size: attachment.size || attachmentResponse.size || bytes.byteLength,
      storageId,
    });
  }
}

async function syncCalendarEvents(
  ctx: ActionCtx,
  userId: Id<"users">,
  googleAccountId: Id<"googleAccounts">,
  providerCalendarId: string,
  accessToken: string,
) {
  const now = new Date(Date.now() - 180 * 24 * 60 * 60 * 1000).toISOString();
  const url = `${CALENDAR_BASE_URL}/calendars/${encodeURIComponent(
    providerCalendarId,
  )}/events?singleEvents=true&orderBy=startTime&timeMin=${encodeURIComponent(now)}&maxResults=250`;
  const events = await googleJson<{ items?: GoogleCalendarEvent[] }>(url, accessToken);
  for (const event of events.items ?? []) {
    if (!event.id) {
      continue;
    }
    await ctx.runMutation(internal.google.upsertCalendarEvent, {
      userId,
      googleAccountId,
      providerCalendarId,
      event,
    });
  }
}

function normalizeBackfillQuery(value?: string) {
  const query = value?.trim();
  return query && query.length > 0 ? query : DEFAULT_GMAIL_BACKFILL_QUERY;
}

function normalizeBackfillMaxPageCount(value?: number): number | undefined {
  if (value === undefined || !Number.isFinite(value)) {
    return undefined;
  }
  return Math.min(Math.max(Math.floor(value), 1), MAX_GMAIL_BACKFILL_MAX_PAGES);
}

async function exchangeAuthorizationCode(code: string): Promise<GoogleTokenResponse> {
  const body = new URLSearchParams({
    code,
    client_id: requireEnv("GOOGLE_CLIENT_ID"),
    client_secret: requireEnv("GOOGLE_CLIENT_SECRET"),
    redirect_uri: requireEnv("GOOGLE_OAUTH_REDIRECT_URI"),
    grant_type: "authorization_code",
  });
  return await googleTokenRequest(body);
}

async function refreshGoogleAccessToken(refreshToken: string): Promise<GoogleTokenResponse> {
  const body = new URLSearchParams({
    refresh_token: refreshToken,
    client_id: requireEnv("GOOGLE_CLIENT_ID"),
    client_secret: requireEnv("GOOGLE_CLIENT_SECRET"),
    grant_type: "refresh_token",
  });
  return await googleTokenRequest(body);
}

async function googleTokenRequest(body: URLSearchParams): Promise<GoogleTokenResponse> {
  const response = await fetch(GOOGLE_TOKEN_URL, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });
  if (!response.ok) {
    throw new Error(`Google token request failed: ${response.status}`);
  }
  return (await response.json()) as GoogleTokenResponse;
}

async function googleJson<T>(url: string, accessToken: string): Promise<T> {
  const response = await fetch(url, { headers: { authorization: `Bearer ${accessToken}` } });
  if (!response.ok) {
    throw new Error(`Google read request failed: ${response.status} ${url}`);
  }
  return (await response.json()) as T;
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is required.`);
  }
  return value;
}

async function encryptionKey() {
  const material = new TextEncoder().encode(requireEnv("GOOGLE_TOKEN_ENCRYPTION_SECRET"));
  const digest = await crypto.subtle.digest("SHA-256", material);
  return await crypto.subtle.importKey("raw", digest, "AES-GCM", false, ["encrypt", "decrypt"]);
}

async function encryptToken(token: string) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const key = await encryptionKey();
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(token));
  return `${bytesToBase64(iv)}.${bytesToBase64(new Uint8Array(encrypted))}`;
}

async function decryptToken(value: string) {
  const [rawIv, rawEncrypted] = value.split(".");
  if (!rawIv || !rawEncrypted) {
    throw new Error("Invalid encrypted token.");
  }
  const key = await encryptionKey();
  const decrypted = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: base64ToBytes(rawIv) },
    key,
    base64ToBytes(rawEncrypted),
  );
  return new TextDecoder().decode(decrypted);
}

function bytesToBase64(bytes: Uint8Array) {
  return btoa(String.fromCharCode(...bytes));
}

function base64ToBytes(value: string) {
  return Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
}

function base64UrlToBytes(value: string) {
  return base64ToBytes(value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "="));
}

function decodeBase64UrlText(value?: string) {
  if (!value) {
    return undefined;
  }
  return new TextDecoder().decode(base64UrlToBytes(value));
}

function gmailMessageIds(response: GmailListResponse | GmailHistoryResponse) {
  if ("messages" in response) {
    return (response.messages ?? []).map((message) => message.id).filter(Boolean);
  }

  const ids = new Set<string>();
  const history = (response as GmailHistoryResponse).history ?? [];
  for (const item of history) {
    for (const added of item.messagesAdded ?? []) {
      if (added.message?.id) {
        ids.add(added.message.id);
      }
    }
  }
  return [...ids];
}

function parseGmailMessage(message: GmailMessage) {
  const headers = new Map((message.payload?.headers ?? []).map((header) => [header.name.toLowerCase(), header.value]));
  const bodies = collectBodies(message.payload);
  return {
    id: message.id,
    threadId: message.threadId,
    historyId: message.historyId,
    labelIds: message.labelIds ?? [],
    from: headers.get("from"),
    to: headers.get("to"),
    cc: headers.get("cc"),
    subject: headers.get("subject"),
    date: headers.get("date") ? Date.parse(headers.get("date")!) : undefined,
    snippet: message.snippet,
    bodyText: bodies.text,
    bodyHtml: bodies.html,
    internalDate: message.internalDate ? Number(message.internalDate) : undefined,
    attachments: bodies.attachments,
  };
}

function collectBodies(part?: GmailPart): {
  text?: string;
  html?: string;
  attachments: Array<{ attachmentId: string; filename: string; mimeType: string; size: number }>;
} {
  const result: {
    text?: string;
    html?: string;
    attachments: Array<{ attachmentId: string; filename: string; mimeType: string; size: number }>;
  } = { attachments: [] };
  if (!part) {
    return result;
  }

  const bodyData = decodeBase64UrlText(part.body?.data);
  if (bodyData && part.mimeType === "text/plain") {
    result.text = [result.text, bodyData].filter(Boolean).join("\n\n");
  }
  if (bodyData && part.mimeType === "text/html") {
    result.html = [result.html, bodyData].filter(Boolean).join("\n\n");
  }
  if (part.body?.attachmentId && part.filename) {
    result.attachments.push({
      attachmentId: part.body.attachmentId,
      filename: part.filename,
      mimeType: part.mimeType ?? "application/octet-stream",
      size: part.body.size ?? 0,
    });
  }

  for (const child of part.parts ?? []) {
    const nested = collectBodies(child);
    result.text = [result.text, nested.text].filter(Boolean).join("\n\n") || undefined;
    result.html = [result.html, nested.html].filter(Boolean).join("\n\n") || undefined;
    result.attachments.push(...nested.attachments);
  }
  return result;
}

function parseGoogleEventDate(date?: { date?: string; dateTime?: string }) {
  const value = date?.dateTime ?? date?.date;
  if (!value) {
    return undefined;
  }
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? undefined : parsed;
}

type GoogleAccountForSync = {
  _id: Id<"googleAccounts">;
  userId: Id<"users">;
  encryptedAccessToken?: string;
  encryptedRefreshToken?: string;
  accessTokenExpiresAt?: number;
};

type GoogleTokenResponse = {
  access_token: string;
  expires_in?: number;
  refresh_token?: string;
  scope?: string;
};

type GmailListResponse = {
  messages?: Array<{ id: string }>;
  nextPageToken?: string;
  resultSizeEstimate?: number;
};
type GmailHistoryResponse = {
  historyId?: string;
  history?: Array<{ messagesAdded?: Array<{ message?: { id?: string } }> }>;
};
type GmailMessage = {
  id: string;
  threadId: string;
  historyId?: string;
  labelIds?: string[];
  snippet?: string;
  internalDate?: string;
  payload?: GmailPart;
};
type GmailPart = {
  mimeType?: string;
  filename?: string;
  headers?: Array<{ name: string; value: string }>;
  body?: { data?: string; attachmentId?: string; size?: number };
  parts?: GmailPart[];
};
type GoogleCalendar = {
  id: string;
  summary?: string;
  description?: string;
  timeZone?: string;
  primary?: boolean;
};
type GoogleCalendarEvent = {
  id: string;
  status?: string;
  summary?: string;
  description?: string;
  location?: string;
  htmlLink?: string;
  start?: { date?: string; dateTime?: string };
  end?: { date?: string; dateTime?: string };
  attendees?: unknown[];
};
