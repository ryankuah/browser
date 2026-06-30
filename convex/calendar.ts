import { v } from "convex/values";
import { query } from "./_generated/server";
import { getCurrentUser } from "./users";

const optionalClientNumber = v.optional(v.union(v.number(), v.int64()));

export const calendars = query({
  args: { sessionToken: v.string() },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    return await ctx.db.query("googleCalendars").withIndex("by_user", (q) => q.eq("userId", userId)).collect();
  },
});

export const events = query({
  args: {
    sessionToken: v.string(),
    from: optionalClientNumber,
    limit: optionalClientNumber,
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const from = normalizeClientNumber(args.from) ?? Date.now() - 30 * 24 * 60 * 60 * 1000;
    const events = await ctx.db
      .query("googleCalendarEvents")
      .withIndex("by_user_start", (q) => q.eq("userId", userId).gte("startTimestamp", from))
      .take(normalizeClientNumber(args.limit) ?? 200);
    return events;
  },
});

export const calendarById = query({
  args: {
    calendarId: v.id("googleCalendars"),
  },
  handler: async (ctx, args) => {
    const calendar = await ctx.db.get(args.calendarId);
    if (!calendar) {
      return null;
    }
    return calendar;
  },
});

function normalizeClientNumber(value?: number | bigint) {
  return typeof value === "bigint" ? Number(value) : value;
}
