import { v } from "convex/values";
import { query } from "./_generated/server";
import { getCurrentUser } from "./users";

const MAX_LIST_BODY_TEXT_LENGTH = 20_000;

export const messages = query({
  args: {
    sessionToken: v.string(),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const messages = await ctx.db
      .query("gmailMessages")
      .withIndex("by_user_recent", (q) => q.eq("userId", userId))
      .order("desc")
      .take(args.limit ?? 100);

    return messages.map(({ bodyHtml: _bodyHtml, bodyText, ...message }) => ({
      ...message,
      bodyText: truncateForList(bodyText),
    }));
  },
});

export const attachmentsForMessage = query({
  args: {
    sessionToken: v.string(),
    googleAccountId: v.id("googleAccounts"),
    providerMessageId: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const attachments = await ctx.db
      .query("gmailAttachments")
      .withIndex("by_message", (q) =>
        q.eq("googleAccountId", args.googleAccountId).eq("providerMessageId", args.providerMessageId),
      )
      .collect();
    return attachments.filter((attachment) => attachment.userId === userId);
  },
});

export const backfillStates = query({
  args: {
    sessionToken: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const accounts = await ctx.db
      .query("googleAccounts")
      .withIndex("by_user", (q) => q.eq("userId", userId))
      .collect();
    const states = [];
    for (const account of accounts) {
      const state = await ctx.db
        .query("gmailSyncState")
        .withIndex("by_account", (q) => q.eq("googleAccountId", account._id))
        .unique();
      states.push({
        googleAccountId: account._id,
        email: account.email,
        status: state?.backfillStatus ?? "idle",
        query: state?.backfillQuery,
        pageCount: state?.backfillPageCount ?? 0,
        maxPageCount: state?.backfillMaxPageCount,
        importedCount: state?.backfillImportedCount ?? 0,
        scannedCount: state?.backfillScannedCount ?? 0,
        resultSizeEstimate: state?.backfillResultSizeEstimate,
        requestedAt: state?.backfillRequestedAt,
        startedAt: state?.backfillStartedAt,
        completedAt: state?.backfillCompletedAt,
        lastError: state?.backfillLastError,
      });
    }
    return states;
  },
});

export const googleAccountForSync = query({
  args: {
    googleAccountId: v.id("googleAccounts"),
  },
  handler: async (ctx, args) => {
    const account = await ctx.db.get(args.googleAccountId);
    if (!account) {
      throw new Error("Google account not found.");
    }
    return account;
  },
});

function truncateForList(value?: string) {
  if (!value || value.length <= MAX_LIST_BODY_TEXT_LENGTH) {
    return value;
  }
  return `${value.slice(0, MAX_LIST_BODY_TEXT_LENGTH)}\n\n[Message body truncated for list view.]`;
}
