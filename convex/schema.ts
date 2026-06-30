import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

export default defineSchema({
  users: defineTable({
    username: v.string(),
    passwordHash: v.string(),
    passwordSalt: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  }).index("by_username", ["username"]),

  userSessions: defineTable({
    userId: v.id("users"),
    tokenHash: v.string(),
    createdAt: v.number(),
    expiresAt: v.number(),
  })
    .index("by_token_hash", ["tokenHash"])
    .index("by_user", ["userId"]),

  browserProfiles: defineTable({
    userId: v.id("users"),
    clientId: v.string(),
    name: v.string(),
    colorHex: v.string(),
    position: v.number(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user_position", ["userId", "position"])
    .index("by_user_client", ["userId", "clientId"]),

  browserSettings: defineTable({
    userId: v.id("users"),
    key: v.string(),
    value: v.string(),
    updatedAt: v.number(),
  }).index("by_user_key", ["userId", "key"]),

  browserSessions: defineTable({
    userId: v.id("users"),
    profileId: v.id("browserProfiles"),
    selectedTabClientId: v.optional(v.string()),
    updatedAt: v.number(),
  }).index("by_user_profile", ["userId", "profileId"]),

  browserTabs: defineTable({
    userId: v.id("users"),
    profileId: v.id("browserProfiles"),
    clientId: v.string(),
    position: v.number(),
    title: v.string(),
    url: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_profile_position", ["profileId", "position"])
    .index("by_profile_client", ["profileId", "clientId"]),

  bookmarks: defineTable({
    userId: v.id("users"),
    profileId: v.id("browserProfiles"),
    clientId: v.string(),
    position: v.number(),
    title: v.string(),
    url: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_profile_position", ["profileId", "position"])
    .index("by_profile_client", ["profileId", "clientId"]),

  historyJourneys: defineTable({
    userId: v.id("users"),
    clientId: v.string(),
    title: v.string(),
    startedAt: v.number(),
    lastVisitedAt: v.number(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user_recent", ["userId", "lastVisitedAt"])
    .index("by_user_client", ["userId", "clientId"]),

  historyVisits: defineTable({
    userId: v.id("users"),
    clientId: v.string(),
    url: v.string(),
    title: v.string(),
    tabClientId: v.optional(v.string()),
    journeyClientId: v.optional(v.string()),
    parentVisitClientId: v.optional(v.string()),
    visitedAt: v.number(),
    origin: v.optional(v.string()),
    createdAt: v.number(),
  })
    .index("by_user_recent", ["userId", "visitedAt"])
    .index("by_user_client", ["userId", "clientId"])
    .index("by_journey", ["userId", "journeyClientId", "visitedAt"]),

  historyUrlStats: defineTable({
    userId: v.id("users"),
    url: v.string(),
    title: v.string(),
    host: v.string(),
    registrableDomain: v.string(),
    subdomain: v.optional(v.string()),
    visitCount: v.number(),
    lastVisitedAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user_url", ["userId", "url"])
    .index("by_user_recent", ["userId", "lastVisitedAt"]),

  googleAccounts: defineTable({
    userId: v.id("users"),
    googleSubject: v.optional(v.string()),
    email: v.string(),
    displayName: v.optional(v.string()),
    scope: v.string(),
    encryptedRefreshToken: v.optional(v.string()),
    encryptedAccessToken: v.optional(v.string()),
    accessTokenExpiresAt: v.optional(v.number()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_user_email", ["userId", "email"])
    .index("by_user", ["userId"]),

  gmailThreads: defineTable({
    userId: v.id("users"),
    googleAccountId: v.id("googleAccounts"),
    providerThreadId: v.string(),
    snippet: v.optional(v.string()),
    historyId: v.optional(v.string()),
    updatedAt: v.number(),
  })
    .index("by_account_thread", ["googleAccountId", "providerThreadId"])
    .index("by_user_updated", ["userId", "updatedAt"]),

  gmailMessages: defineTable({
    userId: v.id("users"),
    googleAccountId: v.id("googleAccounts"),
    providerMessageId: v.string(),
    providerThreadId: v.string(),
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
    importedAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_account_message", ["googleAccountId", "providerMessageId"])
    .index("by_user_recent", ["userId", "internalDate"]),

  gmailAttachments: defineTable({
    userId: v.id("users"),
    googleAccountId: v.id("googleAccounts"),
    providerMessageId: v.string(),
    attachmentId: v.string(),
    filename: v.string(),
    mimeType: v.string(),
    size: v.number(),
    storageId: v.optional(v.id("_storage")),
    importedAt: v.number(),
  }).index("by_message", ["googleAccountId", "providerMessageId"]),

  googleCalendars: defineTable({
    userId: v.id("users"),
    googleAccountId: v.id("googleAccounts"),
    providerCalendarId: v.string(),
    summary: v.string(),
    description: v.optional(v.string()),
    timeZone: v.optional(v.string()),
    primary: v.boolean(),
    selected: v.boolean(),
    syncToken: v.optional(v.string()),
    channelId: v.optional(v.string()),
    channelResourceId: v.optional(v.string()),
    channelExpiresAt: v.optional(v.number()),
    updatedAt: v.number(),
  })
    .index("by_account_calendar", ["googleAccountId", "providerCalendarId"])
    .index("by_user", ["userId"])
    .index("by_channel_id", ["channelId"]),

  googleCalendarEvents: defineTable({
    userId: v.id("users"),
    googleAccountId: v.id("googleAccounts"),
    providerCalendarId: v.string(),
    providerEventId: v.string(),
    status: v.string(),
    summary: v.optional(v.string()),
    description: v.optional(v.string()),
    location: v.optional(v.string()),
    htmlLink: v.optional(v.string()),
    startText: v.optional(v.string()),
    endText: v.optional(v.string()),
    startTimestamp: v.optional(v.number()),
    endTimestamp: v.optional(v.number()),
    attendeesJson: v.optional(v.string()),
    updatedAt: v.number(),
  })
    .index("by_calendar_event", ["googleAccountId", "providerCalendarId", "providerEventId"])
    .index("by_user_start", ["userId", "startTimestamp"]),

  gmailSyncState: defineTable({
    googleAccountId: v.id("googleAccounts"),
    historyId: v.optional(v.string()),
    watchExpiration: v.optional(v.number()),
    backfillStatus: v.optional(v.string()),
    backfillQuery: v.optional(v.string()),
    backfillPageToken: v.optional(v.string()),
    backfillPageCount: v.optional(v.number()),
    backfillMaxPageCount: v.optional(v.number()),
    backfillImportedCount: v.optional(v.number()),
    backfillScannedCount: v.optional(v.number()),
    backfillResultSizeEstimate: v.optional(v.number()),
    backfillRequestedAt: v.optional(v.number()),
    backfillStartedAt: v.optional(v.number()),
    backfillCompletedAt: v.optional(v.number()),
    backfillLastError: v.optional(v.string()),
    updatedAt: v.number(),
  }).index("by_account", ["googleAccountId"]),

  calendarSyncState: defineTable({
    googleAccountId: v.id("googleAccounts"),
    updatedAt: v.number(),
  }).index("by_account", ["googleAccountId"]),

  oauthStates: defineTable({
    userId: v.id("users"),
    state: v.string(),
    createdAt: v.number(),
    expiresAt: v.number(),
  }).index("by_state", ["state"]),

  syncJobs: defineTable({
    userId: v.optional(v.id("users")),
    googleAccountId: v.optional(v.id("googleAccounts")),
    provider: v.string(),
    reason: v.string(),
    payloadJson: v.optional(v.string()),
    status: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_status_created", ["status", "createdAt"])
    .index("by_account_created", ["googleAccountId", "createdAt"]),
});
