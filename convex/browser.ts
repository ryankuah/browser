import { v } from "convex/values";
import { MutationCtx, mutation, query } from "./_generated/server";
import { Id } from "./_generated/dataModel";
import { getCurrentUser } from "./users";

const optionalString = v.optional(v.string());

export const startupData = query({
  args: { sessionToken: v.string() },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const [settings, profiles, journeys, visits, stats] = await Promise.all([
      ctx.db.query("browserSettings").withIndex("by_user_key", (q) => q.eq("userId", userId)).collect(),
      ctx.db.query("browserProfiles").withIndex("by_user_position", (q) => q.eq("userId", userId)).collect(),
      ctx.db.query("historyJourneys").withIndex("by_user_recent", (q) => q.eq("userId", userId)).order("desc").take(100),
      ctx.db.query("historyVisits").withIndex("by_user_recent", (q) => q.eq("userId", userId)).order("desc").take(500),
      ctx.db.query("historyUrlStats").withIndex("by_user_recent", (q) => q.eq("userId", userId)).order("desc").take(1000),
    ]);

    const activeProfileClientId = settings.find((setting) => setting.key === "activeProfileID")?.value;
    const activeProfile =
      profiles.find((profile) => profile.clientId === activeProfileClientId) ?? profiles[0] ?? null;
    const bookmarks = activeProfile
      ? await ctx.db
          .query("bookmarks")
          .withIndex("by_profile_position", (q) => q.eq("profileId", activeProfile._id))
          .collect()
      : [];
    const session = activeProfile
      ? await ctx.db
          .query("browserSessions")
          .withIndex("by_user_profile", (q) => q.eq("userId", userId).eq("profileId", activeProfile._id))
          .unique()
      : null;
    const tabs = activeProfile
      ? await ctx.db
          .query("browserTabs")
          .withIndex("by_profile_position", (q) => q.eq("profileId", activeProfile._id))
          .collect()
      : [];

    return {
      settings,
      profiles,
      activeProfileClientId,
      bookmarks,
      session,
      tabs,
      journeys,
      visits,
      stats,
    };
  },
});

export const saveSettings = mutation({
  args: {
    sessionToken: v.string(),
    settings: v.array(v.object({ key: v.string(), value: v.string() })),
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const now = Date.now();

    for (const setting of args.settings) {
      const existing = await ctx.db
        .query("browserSettings")
        .withIndex("by_user_key", (q) => q.eq("userId", userId).eq("key", setting.key))
        .unique();

      if (existing) {
        await ctx.db.patch(existing._id, { value: setting.value, updatedAt: now });
      } else {
        await ctx.db.insert("browserSettings", { userId, ...setting, updatedAt: now });
      }
    }
  },
});

export const upsertProfiles = mutation({
  args: {
    sessionToken: v.string(),
    profiles: v.array(
      v.object({
        clientId: v.string(),
        name: v.string(),
        colorHex: v.string(),
        position: v.number(),
      }),
    ),
    activeProfileClientId: optionalString,
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const now = Date.now();

    for (const profile of args.profiles) {
      const existing = await ctx.db
        .query("browserProfiles")
        .withIndex("by_user_client", (q) => q.eq("userId", userId).eq("clientId", profile.clientId))
        .unique();

      if (existing) {
        await ctx.db.patch(existing._id, { ...profile, updatedAt: now });
      } else {
        await ctx.db.insert("browserProfiles", { userId, ...profile, createdAt: now, updatedAt: now });
      }
    }

    if (args.activeProfileClientId) {
      const existing = await ctx.db
        .query("browserSettings")
        .withIndex("by_user_key", (q) => q.eq("userId", userId).eq("key", "activeProfileID"))
        .unique();
      if (existing) {
        await ctx.db.patch(existing._id, { value: args.activeProfileClientId, updatedAt: now });
      } else {
        await ctx.db.insert("browserSettings", {
          userId,
          key: "activeProfileID",
          value: args.activeProfileClientId,
          updatedAt: now,
        });
      }
    }
  },
});

export const saveProfileState = mutation({
  args: {
    sessionToken: v.string(),
    profileClientId: v.string(),
    selectedTabClientId: optionalString,
    tabs: v.array(
      v.object({
        clientId: v.string(),
        position: v.number(),
        title: v.string(),
        url: optionalString,
      }),
    ),
    bookmarks: v.array(
      v.object({
        clientId: v.string(),
        position: v.number(),
        title: v.string(),
        url: v.string(),
      }),
    ),
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const profile = await requireProfile(ctx, userId, args.profileClientId);
    const now = Date.now();

    const session = await ctx.db
      .query("browserSessions")
      .withIndex("by_user_profile", (q) => q.eq("userId", userId).eq("profileId", profile))
      .unique();
    if (session) {
      await ctx.db.patch(session._id, { selectedTabClientId: args.selectedTabClientId, updatedAt: now });
    } else {
      await ctx.db.insert("browserSessions", {
        userId,
        profileId: profile,
        selectedTabClientId: args.selectedTabClientId,
        updatedAt: now,
      });
    }

    await replaceProfileCollection(ctx, userId, profile, "browserTabs", args.tabs, now);
    await replaceProfileCollection(ctx, userId, profile, "bookmarks", args.bookmarks, now);
  },
});

export const recordHistoryVisit = mutation({
  args: {
    sessionToken: v.string(),
    clientId: v.string(),
    url: v.string(),
    title: v.string(),
    tabClientId: optionalString,
    journeyClientId: optionalString,
    parentVisitClientId: optionalString,
    visitedAt: v.number(),
    origin: optionalString,
    host: v.string(),
    registrableDomain: v.string(),
    subdomain: optionalString,
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const now = Date.now();
    const existing = await ctx.db
      .query("historyVisits")
      .withIndex("by_user_client", (q) => q.eq("userId", userId).eq("clientId", args.clientId))
      .unique();

    if (!existing) {
      await ctx.db.insert("historyVisits", {
        userId,
        clientId: args.clientId,
        url: args.url,
        title: args.title,
        tabClientId: args.tabClientId,
        journeyClientId: args.journeyClientId,
        parentVisitClientId: args.parentVisitClientId,
        visitedAt: args.visitedAt,
        origin: args.origin,
        createdAt: now,
      });
    }

    if (args.journeyClientId) {
      const journey = await ctx.db
        .query("historyJourneys")
        .withIndex("by_user_client", (q) => q.eq("userId", userId).eq("clientId", args.journeyClientId!))
        .unique();
      if (journey) {
        await ctx.db.patch(journey._id, {
          title: journey.title || args.title,
          lastVisitedAt: Math.max(journey.lastVisitedAt, args.visitedAt),
          updatedAt: now,
        });
      } else {
        await ctx.db.insert("historyJourneys", {
          userId,
          clientId: args.journeyClientId,
          title: args.title,
          startedAt: args.visitedAt,
          lastVisitedAt: args.visitedAt,
          createdAt: now,
          updatedAt: now,
        });
      }
    }

    const stats = await ctx.db
      .query("historyUrlStats")
      .withIndex("by_user_url", (q) => q.eq("userId", userId).eq("url", args.url))
      .unique();
    if (stats) {
      await ctx.db.patch(stats._id, {
        title: args.title,
        visitCount: stats.visitCount + (existing ? 0 : 1),
        lastVisitedAt: Math.max(stats.lastVisitedAt, args.visitedAt),
        updatedAt: now,
      });
    } else {
      await ctx.db.insert("historyUrlStats", {
        userId,
        url: args.url,
        title: args.title,
        host: args.host,
        registrableDomain: args.registrableDomain,
        subdomain: args.subdomain,
        visitCount: 1,
        lastVisitedAt: args.visitedAt,
        updatedAt: now,
      });
    }
  },
});

async function requireProfile(ctx: MutationCtx, userId: Id<"users">, clientId: string) {
  const profile = await ctx.db
    .query("browserProfiles")
    .withIndex("by_user_client", (q) => q.eq("userId", userId).eq("clientId", clientId))
    .unique();
  if (!profile) {
    throw new Error("Profile not found.");
  }
  return profile._id;
}

async function replaceProfileCollection(
  ctx: MutationCtx,
  userId: Id<"users">,
  profileId: Id<"browserProfiles">,
  table: "browserTabs" | "bookmarks",
  items: Array<{ clientId: string; position: number; title: string; url?: string }>,
  now: number,
) {
  const existing = await ctx.db
    .query(table)
    .withIndex("by_profile_position", (q) => q.eq("profileId", profileId))
    .collect();
  const desired = new Set(items.map((item) => item.clientId));

  for (const item of existing) {
    if (!desired.has(item.clientId)) {
      await ctx.db.delete(item._id);
    }
  }

  for (const item of items) {
    const row = existing.find((candidate) => candidate.clientId === item.clientId);
    if (row) {
      await ctx.db.patch(row._id, { ...item, updatedAt: now });
    } else {
      await ctx.db.insert(table, {
        userId,
        profileId,
        clientId: item.clientId,
        position: item.position,
        title: item.title,
        url: item.url ?? "",
        createdAt: now,
        updatedAt: now,
      });
    }
  }
}
