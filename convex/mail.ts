import { v } from "convex/values";
import { mutation, query, QueryCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import { Doc, Id } from "./_generated/dataModel";
import { getCurrentUser } from "./users";

const MAX_LIST_BODY_TEXT_LENGTH = 20_000;
const optionalClientNumber = v.optional(v.union(v.number(), v.int64()));
const DASHBOARD_ITEM_LIMIT = 12;
const DASHBOARD_CANDIDATE_LIMIT = 250;
const DASHBOARD_CALENDAR_PAST_WINDOW_MS = 7 * 24 * 60 * 60 * 1000;
const DASHBOARD_CALENDAR_FUTURE_WINDOW_MS = 90 * 24 * 60 * 60 * 1000;

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

async function withMessages<T extends { [key: string]: unknown }>(
  ctx: QueryCtx,
  rows: T[],
  messageIdField: keyof T,
) {
  const hydrated = [];
  for (const row of rows) {
    const messageId = row[messageIdField];
    const message =
      typeof messageId === "string" ? await ctx.db.get(messageId as unknown as Id<"gmailMessages">) : null;
    hydrated.push({
      ...row,
      message: message ? dashboardMessage(message) : null,
    });
  }
  return hydrated
    .sort((lhs, rhs) => messageSortTimestamp(rhs) - messageSortTimestamp(lhs))
    .slice(0, DASHBOARD_ITEM_LIMIT);
}

async function withClassificationSummaries(
  ctx: QueryCtx,
  classifications: Array<Doc<"mailClassifications">>,
) {
  const hydrated = [];
  for (const classification of classifications.slice(0, DASHBOARD_CANDIDATE_LIMIT)) {
    const message = await ctx.db.get(classification.gmailMessageId);
    hydrated.push({
      ...classification,
      message: message ? dashboardMessage(message) : null,
    });
  }
  return hydrated
    .sort((lhs, rhs) => messageSortTimestamp(rhs) - messageSortTimestamp(lhs))
    .slice(0, DASHBOARD_ITEM_LIMIT);
}

async function withOrderSummaries(
  ctx: QueryCtx,
  orders: Array<Doc<"mailOrders">>,
) {
  const hydrated = [];
  for (const order of orders) {
    const messagesById = new Map<string, ReturnType<typeof dashboardMessage>>();
    if (order.latestGmailMessageId) {
      const latestMessage = await ctx.db.get(order.latestGmailMessageId);
      if (latestMessage) {
        messagesById.set(latestMessage._id, dashboardMessage(latestMessage));
      }
    }

    const shipments = await ctx.db
      .query("mailShipments")
      .withIndex("by_order", (q) => q.eq("orderId", order._id))
      .collect();
    for (const shipment of shipments) {
      const message = await ctx.db.get(shipment.gmailMessageId);
      if (message) {
        messagesById.set(message._id, dashboardMessage(message));
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
    .slice(0, DASHBOARD_ITEM_LIMIT);
}

async function withShipmentSummaries(
  ctx: QueryCtx,
  shipments: Array<Doc<"mailShipments">>,
) {
  const hydrated = [];
  for (const shipment of shipments) {
    const order = shipment.orderId ? await ctx.db.get(shipment.orderId) : null;
    const messagesById = new Map<string, ReturnType<typeof dashboardMessage>>();
    if (shipment.latestGmailMessageId) {
      const latestMessage = await ctx.db.get(shipment.latestGmailMessageId);
      if (latestMessage) {
        messagesById.set(latestMessage._id, dashboardMessage(latestMessage));
      }
    }
    const directMessage = await ctx.db.get(shipment.gmailMessageId);
    if (directMessage) {
      messagesById.set(directMessage._id, dashboardMessage(directMessage));
    }
    const sourceRows = await ctx.db
      .query("mailShipmentMessages")
      .withIndex("by_shipment", (q) => q.eq("shipmentId", shipment._id))
      .collect();
    for (const sourceRow of sourceRows) {
      const message = await ctx.db.get(sourceRow.gmailMessageId);
      if (message) {
        messagesById.set(message._id, dashboardMessage(message));
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
    .slice(0, DASHBOARD_ITEM_LIMIT);
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

async function withInvoiceSummaries(ctx: QueryCtx, invoices: Array<Doc<"mailInvoices">>) {
  const hydrated = [];
  for (const invoice of invoices) {
    const messages = await sourceMessagesForEntity(ctx, {
      latestGmailMessageId: invoice.latestGmailMessageId,
      directGmailMessageId: invoice.gmailMessageId,
      sourceRows: await ctx.db
        .query("mailInvoiceMessages")
        .withIndex("by_invoice", (q) => q.eq("invoiceId", invoice._id))
        .collect(),
    });
    hydrated.push({
      ...invoice,
      message: messages[0] ?? null,
      messages,
    });
  }
  return hydrated
    .sort((lhs, rhs) => messageSortTimestamp(rhs) - messageSortTimestamp(lhs))
    .slice(0, DASHBOARD_ITEM_LIMIT);
}

async function withBookingSummaries(ctx: QueryCtx, bookings: Array<Doc<"mailBookings">>) {
  const hydrated = [];
  for (const booking of bookings) {
    const messages = await sourceMessagesForEntity(ctx, {
      latestGmailMessageId: booking.latestGmailMessageId,
      directGmailMessageId: booking.gmailMessageId,
      sourceRows: await ctx.db
        .query("mailBookingMessages")
        .withIndex("by_booking", (q) => q.eq("bookingId", booking._id))
        .collect(),
    });
    hydrated.push({
      ...booking,
      message: messages[0] ?? null,
      messages,
    });
  }
  return hydrated
    .sort((lhs, rhs) => bookingSortTimestamp(rhs) - bookingSortTimestamp(lhs))
    .slice(0, DASHBOARD_ITEM_LIMIT);
}

async function withMeetingEventSummaries(ctx: QueryCtx, events: Array<Doc<"mailMeetingsEvents">>) {
  const hydrated = [];
  for (const event of events) {
    const messages = await sourceMessagesForEntity(ctx, {
      latestGmailMessageId: event.latestGmailMessageId,
      directGmailMessageId: event.gmailMessageId,
      sourceRows: await ctx.db
        .query("mailMeetingEventMessages")
        .withIndex("by_meeting_event", (q) => q.eq("meetingEventId", event._id))
        .collect(),
    });
    hydrated.push({
      ...event,
      message: messages[0] ?? null,
      messages,
    });
  }
  return hydrated
    .sort((lhs, rhs) => bookingSortTimestamp(rhs) - bookingSortTimestamp(lhs))
    .slice(0, DASHBOARD_ITEM_LIMIT);
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
    const message = await ctx.db.get(gmailMessageId);
    if (message) {
      messagesById.set(message._id, dashboardMessage(message));
    }
  }
  for (const sourceRow of args.sourceRows) {
    const message = await ctx.db.get(sourceRow.gmailMessageId);
    if (message) {
      messagesById.set(message._id, dashboardMessage(message));
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
) {
  const hydrated = [];
  for (const subscription of subscriptions) {
    const messagesById = new Map<string, ReturnType<typeof dashboardMessage>>();
    if (subscription.latestGmailMessageId) {
      const latestMessage = await ctx.db.get(subscription.latestGmailMessageId);
      if (latestMessage) {
        messagesById.set(latestMessage._id, dashboardMessage(latestMessage));
      }
    }
    const sourceRows = await ctx.db
      .query("mailSubscriptionMessages")
      .withIndex("by_subscription", (q) => q.eq("subscriptionId", subscription._id))
      .collect();
    for (const sourceRow of sourceRows) {
      const message = await ctx.db.get(sourceRow.gmailMessageId);
      if (message) {
        messagesById.set(message._id, dashboardMessage(message));
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
    .slice(0, DASHBOARD_ITEM_LIMIT);
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
