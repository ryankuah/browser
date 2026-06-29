import { v } from "convex/values";
import { query } from "./_generated/server";
import { getCurrentUser } from "./users";

export const messages = query({
  args: {
    sessionToken: v.string(),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    return await ctx.db
      .query("gmailMessages")
      .withIndex("by_user_recent", (q) => q.eq("userId", userId))
      .order("desc")
      .take(args.limit ?? 100);
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
