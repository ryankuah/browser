import { v } from "convex/values";
import { paginationOptsValidator } from "convex/server";
import { mutation, query, MutationCtx, QueryCtx } from "./_generated/server";
import { api, internal } from "./_generated/api";
import { Doc, Id } from "./_generated/dataModel";
import { getCurrentUser } from "./users";

const MAX_LIST_BODY_TEXT_LENGTH = 20_000;
const optionalClientNumber = v.optional(v.union(v.number(), v.int64()));
const DASHBOARD_ITEM_LIMIT = 12;
const DASHBOARD_CANDIDATE_LIMIT = 250;
const DASHBOARD_SOURCE_MESSAGE_LIMIT = 12;
const DASHBOARD_CALENDAR_PAST_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;
const DASHBOARD_CALENDAR_FUTURE_WINDOW_MS = 90 * 24 * 60 * 60 * 1000;
const ANALYSIS_BACKFILL_DEFAULT_BATCH_SIZE = 50;
const ANALYSIS_BACKFILL_MAX_BATCH_SIZE = 100;
const ANALYSIS_BACKFILL_DEFAULT_SPACING_MS = 500;
const ANALYSIS_BACKFILL_MIN_SPACING_MS = 100;
const MODEL_UNAVAILABLE_RETRY_SCAN_BATCH_SIZE = 100;
const MESSAGE_SUMMARY_BACKFILL_BATCH_SIZE = 10;

export const messages = query({
  args: {
    sessionToken: v.string(),
    limit: optionalClientNumber,
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const messages = await ctx.db
      .query("gmailMessages")
      .withIndex("by_user_recent", (q) => q.eq("userId", userId))
      .order("desc")
      .take(normalizeClientNumber(args.limit) ?? 100);

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

export const messageBody = query({
  args: {
    sessionToken: v.string(),
    googleAccountId: v.id("googleAccounts"),
    providerMessageId: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const message = await ctx.db
      .query("gmailMessages")
      .withIndex("by_account_message", (q) =>
        q.eq("googleAccountId", args.googleAccountId).eq("providerMessageId", args.providerMessageId),
      )
      .unique();

    if (!message || message.userId !== userId) {
      return null;
    }

    return {
      _id: message._id,
      providerMessageId: message.providerMessageId,
      bodyText: message.bodyText,
      bodyHtml: message.bodyHtml,
    };
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

export const dashboard = query({
  args: {
    sessionToken: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const now = Date.now();
    const classifications = await ctx.db
      .query("mailClassifications")
      .withIndex("by_user_updated", (q) => q.eq("userId", userId))
      .order("desc")
      .take(1000);

    const categoryCounts: Record<string, number> = {};
    for (const classification of classifications) {
      categoryCounts[classification.category] = (categoryCounts[classification.category] ?? 0) + 1;
    }

    const [
      securityCodes,
      securityNotifications,
      notifications,
      supportThreads,
      orders,
      shipments,
      subscriptions,
      invoices,
      bookings,
      meetingsEvents,
      calendarEvents,
    ] = await Promise.all([
      ctx.db
        .query("mailSecurityCodes")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .take(DASHBOARD_CANDIDATE_LIMIT),
      ctx.db
        .query("mailSecurityNotifications")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .take(DASHBOARD_CANDIDATE_LIMIT),
      ctx.db
        .query("mailNotifications")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .take(DASHBOARD_CANDIDATE_LIMIT),
      ctx.db
        .query("mailSupportThreads")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .take(DASHBOARD_CANDIDATE_LIMIT),
      ctx.db
        .query("mailOrders")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .take(DASHBOARD_CANDIDATE_LIMIT),
      ctx.db
        .query("mailShipments")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .take(DASHBOARD_CANDIDATE_LIMIT),
      ctx.db
        .query("mailSubscriptions")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .take(DASHBOARD_CANDIDATE_LIMIT),
      ctx.db
        .query("mailInvoices")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .take(DASHBOARD_CANDIDATE_LIMIT),
      ctx.db
        .query("mailBookings")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .take(DASHBOARD_CANDIDATE_LIMIT),
      ctx.db
        .query("mailMeetingsEvents")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .take(DASHBOARD_CANDIDATE_LIMIT),
      ctx.db
        .query("googleCalendarEvents")
        .withIndex("by_user_start", (q) =>
          q
            .eq("userId", userId)
            .gte("startTimestamp", now - DASHBOARD_CALENDAR_PAST_WINDOW_MS)
            .lte("startTimestamp", now + DASHBOARD_CALENDAR_FUTURE_WINDOW_MS),
        )
        .take(DASHBOARD_CANDIDATE_LIMIT),
    ]);
    const hydratedBookings = await withBookingSummaries(ctx, bookings);
    const hydratedMeetingEvents = await withMeetingEventSummaries(ctx, meetingsEvents);
    const purchaseOnlyOrders = await ordersWithoutShipments(ctx, orders);
    const calendarMeetingRows = calendarEvents.map((event) => ({
      _id: `calendar:${event._id}`,
      source: "calendar",
      provider: "Calendar",
      eventKey: event.providerEventId,
      title: event.summary,
      location: event.location,
      url: event.htmlLink,
      startTime: event.startTimestamp,
      endTime: event.endTimestamp,
      status: event.status,
      updatedAt: event.startTimestamp ?? event.updatedAt,
      message: null,
      messages: [],
    }));

    return {
      categoryCounts,
      securityCodes: await withMessages(ctx, securityCodes, "gmailMessageId"),
      securityNotifications: await withMessages(ctx, securityNotifications, "gmailMessageId"),
      notifications: await withMessages(ctx, notifications, "gmailMessageId"),
      supportThreads: await withMessages(ctx, supportThreads, "latestGmailMessageId"),
      orders: await withOrderSummaries(ctx, purchaseOnlyOrders),
      shipments: await withShipmentSummaries(ctx, shipments),
      subscriptions: await withSubscriptionSummaries(ctx, subscriptions),
      invoices: await withInvoiceSummaries(ctx, invoices),
      bookings: hydratedBookings
        .sort((lhs, rhs) => bookingSortTimestamp(rhs) - bookingSortTimestamp(lhs))
        .slice(0, DASHBOARD_ITEM_LIMIT),
      meetingsEvents: [...hydratedMeetingEvents, ...calendarMeetingRows]
        .sort((lhs, rhs) => meetingEventSortTimestamp(lhs, now) - meetingEventSortTimestamp(rhs, now))
        .slice(0, DASHBOARD_ITEM_LIMIT),
      promotions: await withClassificationSummaries(
        ctx,
        classifications.filter((classification) => classification.category === "promotions"),
      ),
      spam: await withClassificationSummaries(
        ctx,
        classifications.filter((classification) => classification.category === "spam"),
      ),
    };
  },
});

export const dashboardPage = query({
  args: {
    sessionToken: v.string(),
    section: v.string(),
    paginationOpts: paginationOptsValidator,
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const page = await dashboardPageForSection(ctx, userId, args.section, args.paginationOpts);
    return page;
  },
});

async function dashboardPageForSection(
  ctx: QueryCtx,
  userId: Id<"users">,
  section: string,
  paginationOpts: { numItems: number; cursor: string | null },
) {
  const numItems = Math.min(Math.max(Math.floor(paginationOpts.numItems), 1), 24);
  const opts = { ...paginationOpts, numItems };

  switch (section) {
    case "securityCodes": {
      const page = await ctx.db
        .query("mailSecurityCodes")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .paginate(opts);
      return { ...page, page: await withMessages(ctx, page.page, "gmailMessageId", numItems) };
    }
    case "securityNotifications": {
      const page = await ctx.db
        .query("mailSecurityNotifications")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .paginate(opts);
      return { ...page, page: await withMessages(ctx, page.page, "gmailMessageId", numItems) };
    }
    case "notifications": {
      const page = await ctx.db
        .query("mailNotifications")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .paginate(opts);
      return { ...page, page: await withMessages(ctx, page.page, "gmailMessageId", numItems) };
    }
    case "supportThreads": {
      const page = await ctx.db
        .query("mailSupportThreads")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .paginate(opts);
      return { ...page, page: await withMessages(ctx, page.page, "latestGmailMessageId", numItems) };
    }
    case "orders": {
      const page = await ctx.db
        .query("mailOrders")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .paginate(opts);
      const purchaseOnlyOrders = await ordersWithoutShipments(ctx, page.page);
      return { ...page, page: await withOrderSummaries(ctx, purchaseOnlyOrders, numItems) };
    }
    case "shipments": {
      const page = await ctx.db
        .query("mailShipments")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .paginate(opts);
      return { ...page, page: await withShipmentSummaries(ctx, page.page, numItems) };
    }
    case "subscriptions": {
      const page = await ctx.db
        .query("mailSubscriptions")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .paginate(opts);
      return { ...page, page: await withSubscriptionSummaries(ctx, page.page, numItems) };
    }
    case "invoices": {
      const page = await ctx.db
        .query("mailInvoices")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .paginate(opts);
      return { ...page, page: await withInvoiceSummaries(ctx, page.page, numItems) };
    }
    case "bookings": {
      const page = await ctx.db
        .query("mailBookings")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .paginate(opts);
      return { ...page, page: await withBookingSummaries(ctx, page.page, numItems) };
    }
    case "meetingsEvents": {
      const page = await ctx.db
        .query("mailMeetingsEvents")
        .withIndex("by_user_updated", (q) => q.eq("userId", userId))
        .order("desc")
        .paginate(opts);
      return { ...page, page: await withMeetingEventSummaries(ctx, page.page, numItems) };
    }
    case "promotions":
    case "spam": {
      const category = section === "promotions" ? "promotions" : "spam";
      const page = await ctx.db
        .query("mailClassifications")
        .withIndex("by_user_category", (q) => q.eq("userId", userId).eq("category", category))
        .order("desc")
        .paginate(opts);
      return { ...page, page: await withClassificationSummaries(ctx, page.page, numItems) };
    }
    default:
      return { page: [], isDone: true, continueCursor: paginationOpts.cursor ?? "" };
  }
}

async function ordersWithoutShipments<T extends { _id: Id<"mailOrders"> }>(ctx: QueryCtx, orders: T[]) {
  const purchaseOnlyOrders = [];
  for (const order of orders) {
    const linkedShipments = await ctx.db
      .query("mailShipments")
      .withIndex("by_order", (q) => q.eq("orderId", order._id))
      .take(1);
    if (linkedShipments.length === 0) {
      purchaseOnlyOrders.push(order);
    }
  }
  return purchaseOnlyOrders;
}

export const analyzeRecentMessages = mutation({
  args: {
    sessionToken: v.string(),
    limit: optionalClientNumber,
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const messages = await ctx.db
      .query("gmailMessages")
      .withIndex("by_user_recent", (q) => q.eq("userId", userId))
      .order("desc")
      .take(normalizeClientNumber(args.limit) ?? 250);

    for (const message of messages) {
      await ctx.scheduler.runAfter(0, internal.mailAnalysis.analyzeGmailMessage, {
        gmailMessageId: message._id,
      });
    }

    return { scheduled: messages.length };
  },
});

export const analyzeNewestMessagesByEmailDateForDev = mutation({
  args: {
    limit: optionalClientNumber,
  },
  handler: async (ctx, args) => {
    const limit = normalizeClientNumber(args.limit) ?? 50;
    const messages = await ctx.db
      .query("gmailMessages")
      .withIndex("by_internal_date")
      .order("desc")
      .take(limit);

    for (const message of messages) {
      await ctx.scheduler.runAfter(0, internal.mailAnalysis.analyzeGmailMessage, {
        gmailMessageId: message._id,
      });
    }

    return {
      scheduled: messages.length,
      newestEmailDate: messages[0]?.internalDate,
      oldestEmailDate: messages.at(-1)?.internalDate,
    };
  },
});

export const scheduleMailAnalysisBackfill = mutation({
  args: {
    cursor: v.optional(v.union(v.string(), v.null())),
    batchSize: optionalClientNumber,
    spacingMs: optionalClientNumber,
    maxMessages: optionalClientNumber,
    scheduledSoFar: optionalClientNumber,
    force: v.optional(v.boolean()),
  },
  handler: async (ctx, args) => {
    const batchSize = Math.min(
      Math.max(Math.floor(normalizeClientNumber(args.batchSize) ?? ANALYSIS_BACKFILL_DEFAULT_BATCH_SIZE), 1),
      ANALYSIS_BACKFILL_MAX_BATCH_SIZE,
    );
    const spacingMs = Math.max(
      Math.floor(normalizeClientNumber(args.spacingMs) ?? ANALYSIS_BACKFILL_DEFAULT_SPACING_MS),
      ANALYSIS_BACKFILL_MIN_SPACING_MS,
    );
    const scheduledSoFar = Math.max(Math.floor(normalizeClientNumber(args.scheduledSoFar) ?? 0), 0);
    const maxMessages = normalizeClientNumber(args.maxMessages);
    const remaining = maxMessages === undefined ? batchSize : Math.max(Math.floor(maxMessages) - scheduledSoFar, 0);

    if (remaining <= 0) {
      return {
        scheduled: 0,
        skipped: 0,
        scheduledSoFar,
        done: true,
        reason: "maxMessages reached",
      };
    }

    const page = await ctx.db
      .query("gmailMessages")
      .withIndex("by_internal_date")
      .order("desc")
      .paginate({
        numItems: Math.min(batchSize, remaining),
        cursor: args.cursor ?? null,
      });

    let scheduled = 0;
    let skipped = 0;
    for (const message of page.page) {
      if (!args.force) {
        const existing = await ctx.db
          .query("mailClassifications")
          .withIndex("by_message_and_category", (q) => q.eq("gmailMessageId", message._id))
          .take(1);
        if (existing.length > 0) {
          skipped += 1;
          continue;
        }
      }

      await ctx.scheduler.runAfter(scheduled * spacingMs, internal.mailAnalysis.analyzeGmailMessage, {
        gmailMessageId: message._id,
      });
      scheduled += 1;
    }

    const nextScheduledSoFar = scheduledSoFar + scheduled;
    const hitMaxMessages = maxMessages !== undefined && nextScheduledSoFar >= Math.floor(maxMessages);
    const done = page.isDone || hitMaxMessages;
    if (!done) {
      const nextArgs: {
        cursor: string;
        batchSize: number;
        spacingMs: number;
        maxMessages?: number;
        scheduledSoFar: number;
        force?: boolean;
      } = {
        cursor: page.continueCursor,
        batchSize,
        spacingMs,
        scheduledSoFar: nextScheduledSoFar,
      };
      if (maxMessages !== undefined) {
        nextArgs.maxMessages = maxMessages;
      }
      if (args.force !== undefined) {
        nextArgs.force = args.force;
      }
      await ctx.scheduler.runAfter(
        Math.max(scheduled * spacingMs + 1_000, 1_000),
        api.mail.scheduleMailAnalysisBackfill,
        nextArgs,
      );
    }

    return {
      scheduled,
      skipped,
      scheduledSoFar: nextScheduledSoFar,
      scanned: page.page.length,
      batchSize,
      spacingMs,
      continueCursor: page.continueCursor,
      done,
    };
  },
});

export const mailAnalysisBackfillStatus = query({
  args: {
    sampleLimit: optionalClientNumber,
  },
  handler: async (ctx, args) => {
    const limit = Math.min(Math.max(Math.floor(normalizeClientNumber(args.sampleLimit) ?? 25), 1), 50);
    const messages = await ctx.db.query("gmailMessages").withIndex("by_internal_date").order("desc").take(limit);
    const classifiedMessageIds = new Set<Id<"gmailMessages">>();
    const categoryCounts: Record<string, number> = {};
    let sampledClassifications = 0;
    for (const message of messages) {
      const rows = await ctx.db
        .query("mailClassifications")
        .withIndex("by_message_and_category", (q) => q.eq("gmailMessageId", message._id))
        .collect();
      if (rows.length > 0) {
        classifiedMessageIds.add(message._id);
      }
      sampledClassifications += rows.length;
      for (const classification of rows) {
        categoryCounts[classification.category] = (categoryCounts[classification.category] ?? 0) + 1;
      }
    }
    const unclassified = messages
      .filter((message) => !classifiedMessageIds.has(message._id))
      .slice(0, 20)
      .map((message) => ({
        gmailMessageId: message._id,
        internalDate: message.internalDate,
        from: message.from,
        subject: message.subject,
      }));

    return {
      sampledMessages: messages.length,
      sampledClassifications,
      uniqueClassifiedMessages: classifiedMessageIds.size,
      sampledUnclassifiedMessages: Math.max(messages.length - classifiedMessageIds.size, 0),
      categoryCounts,
      unclassified,
    };
  },
});

export const scheduleGmailMessageSummaryBackfill = mutation({
  args: {
    cursor: v.optional(v.union(v.string(), v.null())),
    maxMessages: optionalClientNumber,
    processedSoFar: optionalClientNumber,
  },
  handler: async (ctx, args) => {
    const processedSoFar = Math.max(Math.floor(normalizeClientNumber(args.processedSoFar) ?? 0), 0);
    const maxMessages = normalizeClientNumber(args.maxMessages);
    const remaining =
      maxMessages === undefined
        ? MESSAGE_SUMMARY_BACKFILL_BATCH_SIZE
        : Math.max(Math.floor(maxMessages) - processedSoFar, 0);

    if (remaining <= 0) {
      return {
        processed: 0,
        processedSoFar,
        done: true,
        reason: "maxMessages reached",
      };
    }

    const page = await ctx.db
      .query("gmailMessages")
      .withIndex("by_internal_date")
      .order("desc")
      .paginate({
        numItems: Math.min(MESSAGE_SUMMARY_BACKFILL_BATCH_SIZE, remaining),
        cursor: args.cursor ?? null,
      });

    for (const message of page.page) {
      await upsertGmailMessageSummaryFromMessage(ctx, message);
    }

    const nextProcessedSoFar = processedSoFar + page.page.length;
    const hitMaxMessages = maxMessages !== undefined && nextProcessedSoFar >= Math.floor(maxMessages);
    const done = page.isDone || hitMaxMessages;
    if (!done) {
      const nextArgs: {
        cursor: string;
        maxMessages?: number;
        processedSoFar: number;
      } = {
        cursor: page.continueCursor,
        processedSoFar: nextProcessedSoFar,
      };
      if (maxMessages !== undefined) {
        nextArgs.maxMessages = maxMessages;
      }
      await ctx.scheduler.runAfter(250, api.mail.scheduleGmailMessageSummaryBackfill, nextArgs);
    }

    return {
      processed: page.page.length,
      processedSoFar: nextProcessedSoFar,
      continueCursor: page.continueCursor,
      done,
    };
  },
});

export const scheduleModelUnavailableRetry = mutation({
  args: {
    cursor: v.optional(v.union(v.string(), v.null())),
    spacingMs: optionalClientNumber,
    maxRetries: optionalClientNumber,
    scannedSoFar: optionalClientNumber,
    scheduledSoFar: optionalClientNumber,
  },
  handler: async (ctx, args) => {
    const spacingMs = Math.max(
      Math.floor(normalizeClientNumber(args.spacingMs) ?? ANALYSIS_BACKFILL_DEFAULT_SPACING_MS),
      ANALYSIS_BACKFILL_MIN_SPACING_MS,
    );
    const scannedSoFar = Math.max(Math.floor(normalizeClientNumber(args.scannedSoFar) ?? 0), 0);
    const scheduledSoFar = Math.max(Math.floor(normalizeClientNumber(args.scheduledSoFar) ?? 0), 0);
    const maxRetries = normalizeClientNumber(args.maxRetries);
    const remainingRetries =
      maxRetries === undefined ? undefined : Math.max(Math.floor(maxRetries) - scheduledSoFar, 0);

    if (remainingRetries === 0) {
      return {
        scanned: 0,
        scheduled: 0,
        scannedSoFar,
        scheduledSoFar,
        done: true,
        reason: "maxRetries reached",
      };
    }

    const page = await ctx.db.query("mailClassifications").paginate({
      numItems: MODEL_UNAVAILABLE_RETRY_SCAN_BATCH_SIZE,
      cursor: args.cursor ?? null,
    });
    const scheduledMessageIds = new Set<string>();
    let scheduled = 0;
    for (const classification of page.page) {
      if (classification.source !== "model_unavailable") {
        continue;
      }
      if (remainingRetries !== undefined && scheduled >= remainingRetries) {
        break;
      }
      if (scheduledMessageIds.has(classification.gmailMessageId)) {
        continue;
      }
      scheduledMessageIds.add(classification.gmailMessageId);
      await ctx.scheduler.runAfter(scheduled * spacingMs, internal.mailAnalysis.analyzeGmailMessage, {
        gmailMessageId: classification.gmailMessageId,
      });
      scheduled += 1;
    }

    const nextScannedSoFar = scannedSoFar + page.page.length;
    const nextScheduledSoFar = scheduledSoFar + scheduled;
    const hitMaxRetries = maxRetries !== undefined && nextScheduledSoFar >= Math.floor(maxRetries);
    const done = page.isDone || hitMaxRetries;
    if (!done) {
      const nextArgs: {
        cursor: string;
        spacingMs: number;
        maxRetries?: number;
        scannedSoFar: number;
        scheduledSoFar: number;
      } = {
        cursor: page.continueCursor,
        spacingMs,
        scannedSoFar: nextScannedSoFar,
        scheduledSoFar: nextScheduledSoFar,
      };
      if (maxRetries !== undefined) {
        nextArgs.maxRetries = maxRetries;
      }
      await ctx.scheduler.runAfter(
        Math.max(scheduled * spacingMs + 1_000, 1_000),
        api.mail.scheduleModelUnavailableRetry,
        nextArgs,
      );
    }

    return {
      scanned: page.page.length,
      scheduled,
      scannedSoFar: nextScannedSoFar,
      scheduledSoFar: nextScheduledSoFar,
      continueCursor: page.continueCursor,
      done,
    };
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

export const shippingDashboardSummaryForDev = query({
  args: {},
  handler: async (ctx) => {
    const orders = await ctx.db.query("mailOrders").order("desc").take(DASHBOARD_CANDIDATE_LIMIT);
    const purchaseOnlyOrders = await ordersWithoutShipments(ctx, orders);
    const hydratedOrders = await withOrderSummaries(ctx, purchaseOnlyOrders);
    const shipments = await ctx.db.query("mailShipments").order("desc").take(DASHBOARD_CANDIDATE_LIMIT);
    const hydrated = await withShipmentSummaries(ctx, shipments);
    return {
      purchases: hydratedOrders.map((order) => ({
        itemSummary: order.itemSummary,
        merchant: order.merchant,
        orderNumber: order.orderNumber,
        status: order.status,
        imageUrl: order.imageUrl,
        sourceEmailCount: order.messages.length,
      })),
      shipments: hydrated.map((shipment) => ({
        itemSummary: shipment.itemSummary,
        merchant: shipment.merchant,
        carrier: shipment.carrier,
        trackingNumber: shipment.trackingNumber,
        status: shipment.status,
        imageUrl: shipment.imageUrl,
        sourceEmailCount: shipment.messages.length,
      })),
    };
  },
});

function truncateForList(value?: string) {
  if (!value || value.length <= MAX_LIST_BODY_TEXT_LENGTH) {
    return value;
  }
  return `${value.slice(0, MAX_LIST_BODY_TEXT_LENGTH)}\n\n[Message body truncated for list view.]`;
}

function normalizeClientNumber(value?: number | bigint) {
  return typeof value === "bigint" ? Number(value) : value;
}

async function upsertGmailMessageSummaryFromMessage(ctx: MutationCtx, message: Doc<"gmailMessages">) {
  const [existing] = await ctx.db
    .query("gmailMessageSummaries")
    .withIndex("by_message", (q) => q.eq("gmailMessageId", message._id))
    .take(1);
  const row = {
    userId: message.userId,
    gmailMessageId: message._id,
    googleAccountId: message.googleAccountId,
    providerMessageId: message.providerMessageId,
    providerThreadId: message.providerThreadId,
    from: message.from,
    subject: message.subject,
    snippet: message.snippet,
    internalDate: message.internalDate,
    updatedAt: message.updatedAt,
  };
  if (existing) {
    await ctx.db.patch(existing._id, row);
  } else {
    await ctx.db.insert("gmailMessageSummaries", row);
  }
}

async function dashboardMessageForId(ctx: QueryCtx, gmailMessageId: Id<"gmailMessages">) {
  const [summary] = await ctx.db
    .query("gmailMessageSummaries")
    .withIndex("by_message", (q) => q.eq("gmailMessageId", gmailMessageId))
    .take(1);
  return summary ? dashboardMessageFromSummary(summary) : null;
}

async function withMessages<T extends { [key: string]: unknown }>(
  ctx: QueryCtx,
  rows: T[],
  messageIdField: keyof T,
  limit = DASHBOARD_ITEM_LIMIT,
) {
  const hydrated = [];
  for (const row of rows.slice(0, limit)) {
    const messageId = row[messageIdField];
    const message =
      typeof messageId === "string"
        ? await dashboardMessageForId(ctx, messageId as unknown as Id<"gmailMessages">)
        : null;
    hydrated.push({
      ...row,
      message,
    });
  }
  return hydrated
    .sort((lhs, rhs) => messageSortTimestamp(rhs) - messageSortTimestamp(lhs))
    .slice(0, limit);
}

async function withClassificationSummaries(
  ctx: QueryCtx,
  classifications: Array<Doc<"mailClassifications">>,
  limit = DASHBOARD_ITEM_LIMIT,
) {
  const hydrated = [];
  for (const classification of classifications.slice(0, limit)) {
    const message = await dashboardMessageForId(ctx, classification.gmailMessageId);
    hydrated.push({
      ...classification,
      message,
    });
  }
  return hydrated
    .sort((lhs, rhs) => messageSortTimestamp(rhs) - messageSortTimestamp(lhs))
    .slice(0, limit);
}

async function withOrderSummaries(
  ctx: QueryCtx,
  orders: Array<Doc<"mailOrders">>,
  limit = DASHBOARD_ITEM_LIMIT,
) {
  const hydrated = [];
  for (const order of orders.slice(0, limit)) {
    const messagesById = new Map<string, ReturnType<typeof dashboardMessage>>();
    if (order.latestGmailMessageId) {
      const latestMessage = await dashboardMessageForId(ctx, order.latestGmailMessageId);
      if (latestMessage) {
        messagesById.set(latestMessage._id, latestMessage);
      }
    }

    const shipments = await ctx.db
      .query("mailShipments")
      .withIndex("by_order", (q) => q.eq("orderId", order._id))
      .order("desc")
      .take(DASHBOARD_SOURCE_MESSAGE_LIMIT);
    for (const shipment of shipments) {
      const message = await dashboardMessageForId(ctx, shipment.gmailMessageId);
      if (message) {
        messagesById.set(message._id, message);
      }
    }

    const messages = [...messagesById.values()].sort((lhs, rhs) => (rhs.internalDate ?? 0) - (lhs.internalDate ?? 0));
    hydrated.push({
      ...order,
      itemSummary: typeof order.itemSummary === "string" ? cleanItemSummary(order.itemSummary) : order.itemSummary,
      message: messages[0] ?? null,
      messages,
    });
  }

  return hydrated
    .sort((lhs, rhs) => messageSortTimestamp(rhs) - messageSortTimestamp(lhs))
    .slice(0, limit);
}

async function withShipmentSummaries(
  ctx: QueryCtx,
  shipments: Array<Doc<"mailShipments">>,
  limit = DASHBOARD_ITEM_LIMIT,
) {
  const hydrated = [];
  for (const shipment of shipments.slice(0, limit)) {
    const order = shipment.orderId ? await ctx.db.get(shipment.orderId) : null;
    const messagesById = new Map<string, ReturnType<typeof dashboardMessage>>();
    if (shipment.latestGmailMessageId) {
      const latestMessage = await dashboardMessageForId(ctx, shipment.latestGmailMessageId);
      if (latestMessage) {
        messagesById.set(latestMessage._id, latestMessage);
      }
    }
    const directMessage = await dashboardMessageForId(ctx, shipment.gmailMessageId);
    if (directMessage) {
      messagesById.set(directMessage._id, directMessage);
    }
    const sourceRows = await ctx.db
      .query("mailShipmentMessages")
      .withIndex("by_shipment", (q) => q.eq("shipmentId", shipment._id))
      .order("desc")
      .take(DASHBOARD_SOURCE_MESSAGE_LIMIT);
    for (const sourceRow of sourceRows) {
      const message = await dashboardMessageForId(ctx, sourceRow.gmailMessageId);
      if (message) {
        messagesById.set(message._id, message);
      }
    }
    const messages = [...messagesById.values()].sort((lhs, rhs) => (rhs.internalDate ?? 0) - (lhs.internalDate ?? 0));
    const itemSummary = cleanItemSummary(shipment.itemSummary ?? order?.itemSummary);
    hydrated.push({
      ...shipment,
      itemSummary,
      imageUrl: shipment.imageUrl ?? order?.imageUrl,
      orderNumber: order?.orderNumber,
      status: displayShipmentStatus(shipment.status),
      message: messages[0] ?? null,
      messages,
    });
  }

  return hydrated
    .sort((lhs, rhs) => messageSortTimestamp(rhs) - messageSortTimestamp(lhs))
    .slice(0, limit);
}

function displayShipmentStatus(status: string) {
  const normalized = normalizedDashboardKey(status, "");
  if (normalized.includes("out:for:delivery")) return "out_for_delivery";
  if (normalized.includes("on:the:way") || normalized.includes("in:transit")) return "in_transit";
  if (normalized.includes("shipped")) return "shipped";
  if (normalized.includes("delivered")) return "delivered";
  return status;
}

function cleanItemSummary(value?: string) {
  return value?.replace(/^\s*[*\-•]\s*/, "").trim() || undefined;
}

function normalizedDashboardKey(prefix: string, value: string) {
  return `${prefix}:${value}`.toLowerCase().replace(/[^a-z0-9]+/g, ":").replace(/^:|:$/g, "");
}

async function withInvoiceSummaries(ctx: QueryCtx, invoices: Array<Doc<"mailInvoices">>, limit = DASHBOARD_ITEM_LIMIT) {
  const hydrated = [];
  for (const invoice of invoices.slice(0, limit)) {
    const messages = await sourceMessagesForEntity(ctx, {
      latestGmailMessageId: invoice.latestGmailMessageId,
      directGmailMessageId: invoice.gmailMessageId,
      sourceRows: await ctx.db
        .query("mailInvoiceMessages")
        .withIndex("by_invoice", (q) => q.eq("invoiceId", invoice._id))
        .order("desc")
        .take(DASHBOARD_SOURCE_MESSAGE_LIMIT),
    });
    hydrated.push({
      ...invoice,
      message: messages[0] ?? null,
      messages,
    });
  }
  return hydrated
    .sort((lhs, rhs) => messageSortTimestamp(rhs) - messageSortTimestamp(lhs))
    .slice(0, limit);
}

async function withBookingSummaries(ctx: QueryCtx, bookings: Array<Doc<"mailBookings">>, limit = DASHBOARD_ITEM_LIMIT) {
  const hydrated = [];
  for (const booking of bookings.slice(0, limit)) {
    const messages = await sourceMessagesForEntity(ctx, {
      latestGmailMessageId: booking.latestGmailMessageId,
      directGmailMessageId: booking.gmailMessageId,
      sourceRows: await ctx.db
        .query("mailBookingMessages")
        .withIndex("by_booking", (q) => q.eq("bookingId", booking._id))
        .order("desc")
        .take(DASHBOARD_SOURCE_MESSAGE_LIMIT),
    });
    hydrated.push({
      ...booking,
      message: messages[0] ?? null,
      messages,
    });
  }
  return hydrated
    .sort((lhs, rhs) => bookingSortTimestamp(rhs) - bookingSortTimestamp(lhs))
    .slice(0, limit);
}

async function withMeetingEventSummaries(
  ctx: QueryCtx,
  events: Array<Doc<"mailMeetingsEvents">>,
  limit = DASHBOARD_ITEM_LIMIT,
) {
  const hydrated = [];
  for (const event of events.slice(0, limit)) {
    const messages = await sourceMessagesForEntity(ctx, {
      latestGmailMessageId: event.latestGmailMessageId,
      directGmailMessageId: event.gmailMessageId,
      sourceRows: await ctx.db
        .query("mailMeetingEventMessages")
        .withIndex("by_meeting_event", (q) => q.eq("meetingEventId", event._id))
        .order("desc")
        .take(DASHBOARD_SOURCE_MESSAGE_LIMIT),
    });
    hydrated.push({
      ...event,
      message: messages[0] ?? null,
      messages,
    });
  }
  return hydrated
    .sort((lhs, rhs) => bookingSortTimestamp(rhs) - bookingSortTimestamp(lhs))
    .slice(0, limit);
}

async function sourceMessagesForEntity(
  ctx: QueryCtx,
  args: {
    latestGmailMessageId?: Id<"gmailMessages">;
    directGmailMessageId?: Id<"gmailMessages">;
    sourceRows: Array<{ gmailMessageId: Id<"gmailMessages"> }>;
  },
) {
  const messagesById = new Map<string, ReturnType<typeof dashboardMessage>>();
  for (const gmailMessageId of [args.latestGmailMessageId, args.directGmailMessageId]) {
    if (!gmailMessageId) continue;
    const message = await dashboardMessageForId(ctx, gmailMessageId);
    if (message) {
      messagesById.set(message._id, message);
    }
  }
  for (const sourceRow of args.sourceRows) {
    const message = await dashboardMessageForId(ctx, sourceRow.gmailMessageId);
    if (message) {
      messagesById.set(message._id, message);
    }
  }
  return [...messagesById.values()].sort((lhs, rhs) => (rhs.internalDate ?? 0) - (lhs.internalDate ?? 0));
}

async function withSubscriptionSummaries(
  ctx: QueryCtx,
  subscriptions: Array<{
    _id: Id<"mailSubscriptions">;
    subscriptionKey: string;
    latestGmailMessageId?: Id<"gmailMessages">;
    updatedAt: number;
    [key: string]: unknown;
  }>,
  limit = DASHBOARD_ITEM_LIMIT,
) {
  const hydrated = [];
  for (const subscription of subscriptions.slice(0, limit)) {
    const messagesById = new Map<string, ReturnType<typeof dashboardMessage>>();
    if (subscription.latestGmailMessageId) {
      const latestMessage = await dashboardMessageForId(ctx, subscription.latestGmailMessageId);
      if (latestMessage) {
        messagesById.set(latestMessage._id, latestMessage);
      }
    }
    const sourceRows = await ctx.db
      .query("mailSubscriptionMessages")
      .withIndex("by_subscription", (q) => q.eq("subscriptionId", subscription._id))
      .order("desc")
      .take(DASHBOARD_SOURCE_MESSAGE_LIMIT);
    for (const sourceRow of sourceRows) {
      const message = await dashboardMessageForId(ctx, sourceRow.gmailMessageId);
      if (message) {
        messagesById.set(message._id, message);
      }
    }
    const messages = [...messagesById.values()].sort((lhs, rhs) => (rhs.internalDate ?? 0) - (lhs.internalDate ?? 0));
    hydrated.push({
      ...subscription,
      message: messages[0] ?? null,
      messages,
    });
  }
  return hydrated
    .sort((lhs, rhs) => messageSortTimestamp(rhs) - messageSortTimestamp(lhs))
    .slice(0, limit);
}

function dashboardMessageFromSummary(summary: {
  gmailMessageId: Id<"gmailMessages">;
  googleAccountId: Id<"googleAccounts">;
  providerMessageId: string;
  providerThreadId: string;
  from?: string;
  subject?: string;
  snippet?: string;
  internalDate?: number;
}) {
  return {
    _id: summary.gmailMessageId,
    googleAccountId: summary.googleAccountId,
    providerMessageId: summary.providerMessageId,
    providerThreadId: summary.providerThreadId,
    from: summary.from,
    subject: summary.subject,
    snippet: summary.snippet,
    internalDate: summary.internalDate,
  };
}

function dashboardMessage(message: {
  _id: Id<"gmailMessages">;
  googleAccountId: Id<"googleAccounts">;
  providerMessageId: string;
  providerThreadId: string;
  from?: string;
  subject?: string;
  snippet?: string;
  internalDate?: number;
}) {
  return {
    _id: message._id,
    googleAccountId: message.googleAccountId,
    providerMessageId: message.providerMessageId,
    providerThreadId: message.providerThreadId,
    from: message.from,
    subject: message.subject,
    snippet: message.snippet,
    internalDate: message.internalDate,
  };
}

function messageSortTimestamp(row: { message: { internalDate?: number } | null; updatedAt?: unknown }) {
  if (typeof row.message?.internalDate === "number") {
    return row.message.internalDate;
  }
  return typeof row.updatedAt === "number" ? row.updatedAt : 0;
}

function bookingSortTimestamp(row: {
  startTime?: unknown;
  message: { internalDate?: number } | null;
  updatedAt?: unknown;
}) {
  if (typeof row.startTime === "number") {
    return row.startTime;
  }
  return messageSortTimestamp(row);
}

function meetingEventSortTimestamp(
  row: {
    startTime?: unknown;
    message: { internalDate?: number } | null;
    updatedAt?: unknown;
  },
  now: number,
) {
  const timestamp = bookingSortTimestamp(row);
  if (timestamp >= now - DASHBOARD_CALENDAR_PAST_WINDOW_MS) {
    return timestamp;
  }
  return Number.MAX_SAFE_INTEGER - timestamp;
}
