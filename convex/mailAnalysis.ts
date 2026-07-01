import { v } from "convex/values";
import { ActionCtx, internalAction, internalMutation, internalQuery, MutationCtx, QueryCtx } from "./_generated/server";
import { internal } from "./_generated/api";
import { Doc, Id } from "./_generated/dataModel";

type MessageDoc = Doc<"gmailMessages">;
type ModelCategory =
  | "spam"
  | "promotions"
  | "security_code"
  | "security_notifications"
  | "notifications"
  | "support"
  | "purchase"
  | "shipping"
  | "subscription"
  | "invoice"
  | "bookings"
  | "meetings_events"
  | "unknown";

type ModelEmailAnalysis = {
  category: ModelCategory;
  confidence?: number;
  reason?: string;
  decisiveSignals?: string[];
  possibleAlternativeCategories?: string[];
  suggestedCategory?: ModelCategory;
  notificationType?: string;
  accountEmail?: string;
  serviceName?: string;
  code?: string;
  url?: string;
  ipAddress?: string;
  location?: string;
  device?: string;
  app?: string;
  companyName?: string;
  ticketId?: string;
  status?: string;
  merchant?: string;
  orderNumber?: string;
  itemSummary?: string;
  imageUrl?: string;
  carrier?: string;
  trackingNumber?: string;
  trackingUrl?: string;
  vendor?: string;
  invoiceNumber?: string;
  amount?: number;
  currency?: string;
  nextPaymentDueAt?: string;
  bookingCategory?: string;
  provider?: string;
  confirmationNumber?: string;
  bookingCode?: string;
  bookingUrl?: string;
  qrCodeUrl?: string;
  ticketUrl?: string;
  title?: string;
  startTime?: string;
  endTime?: string;
  occurredAt?: string;
  missingButExpectedFields?: string[];
  mergeTargetId?: string;
  mergeDecisionReason?: string;
  mergeConfidence?: number;
};

const CATEGORY_LABELS: Record<string, string> = {
  spam: "Spam",
  promotions: "Promotions",
  security_code: "Security Codes",
  security_notifications: "Security Notifications",
  notifications: "Notifications",
  support: "Support",
  purchase: "Purchases",
  shipping: "Shipping",
  subscription: "Subscriptions",
  invoice: "Invoices",
  bookings: "Bookings",
  meetings_events: "Meetings & Events",
};

const DEFAULT_OPENROUTER_MODEL = "deepseek/deepseek-v4-flash";
const DEFAULT_OPENROUTER_REASONING_EFFORT = "xhigh";
const DEFAULT_OPENROUTER_TIMEOUT_MS = 90_000;

export const analyzeGmailMessage = internalMutation({
  args: {
    gmailMessageId: v.id("gmailMessages"),
  },
  handler: async (ctx, args) => {
    const message = await ctx.db.get(args.gmailMessageId);
    if (!message) {
      return null;
    }

    await clearMessageAnalysis(ctx, args.gmailMessageId);
    await ctx.scheduler.runAfter(0, internal.mailAnalysis.analyzeGmailMessageWithModel, {
      gmailMessageId: message._id,
    });

    return { scheduled: true };
  },
});

export const analyzeGmailMessageWithModel = internalAction({
  args: {
    gmailMessageId: v.id("gmailMessages"),
  },
  handler: async (ctx, args) => {
    const message: MessageForModel | null = await ctx.runQuery(internal.mailAnalysis.gmailMessageForModel, {
      gmailMessageId: args.gmailMessageId,
    });
    if (!message) {
      return null;
    }

    const baselineAnalysis = gmailLabelBaselineAnalysis(message);
    if (baselineAnalysis) {
      await ctx.runMutation(internal.mailAnalysis.applyModelAnalysis, {
        gmailMessageId: args.gmailMessageId,
        analysis: baselineAnalysis,
        model: "gmail-label-baseline",
        source: "gmail_label",
      });
      return { category: baselineAnalysis.category, source: "gmail_label" };
    }

    const apiKey = process.env.OPENROUTER_API_KEY;
    if (!apiKey) {
      const analysis = fallbackAnalysisForModelFailure(message, "OPENROUTER_API_KEY is not configured.");
      await ctx.runMutation(internal.mailAnalysis.applyModelAnalysis, {
        gmailMessageId: args.gmailMessageId,
        analysis,
        model: "local-fallback",
        source: "model_unavailable",
      });
      return { category: analysis.category, source: "model_unavailable" };
    }

    const model = process.env.OPENROUTER_MODEL || DEFAULT_OPENROUTER_MODEL;
    let analysis: ModelEmailAnalysis;
    try {
      analysis = await analyzeWithOpenRouterPipeline(apiKey, message);
      analysis = await maybeResolveMergeTargetWithOpenRouter(ctx, apiKey, message, analysis);
    } catch (error) {
      analysis = fallbackAnalysisForModelFailure(message, errorMessage(error));
      await ctx.runMutation(internal.mailAnalysis.applyModelAnalysis, {
        gmailMessageId: args.gmailMessageId,
        analysis,
        model,
        source: "model_fallback",
      });
      return { category: analysis.category, source: "model_fallback", error: errorMessage(error) };
    }

    await ctx.runMutation(internal.mailAnalysis.applyModelAnalysis, {
      gmailMessageId: args.gmailMessageId,
      analysis,
      model,
      source: "model",
    });
    return { category: analysis.category };
  },
});

export const gmailMessageForModel = internalQuery({
  args: {
    gmailMessageId: v.id("gmailMessages"),
  },
  handler: async (ctx, args) => {
    const message = await ctx.db.get(args.gmailMessageId);
    if (!message) {
      return null;
    }

    return {
      _id: message._id,
      userId: message.userId,
      googleAccountId: message.googleAccountId,
      providerMessageId: message.providerMessageId,
      providerThreadId: message.providerThreadId,
      from: message.from,
      to: message.to,
      subject: message.subject,
      labelIds: message.labelIds,
      snippet: message.snippet,
      bodyText: truncateForModel(message.bodyText),
      imageUrls: extractImageUrls(message.bodyHtml),
      internalDate: message.internalDate,
    };
  },
});

export const mergeCandidatesForModel = internalQuery({
  args: {
    userId: v.id("users"),
    category: v.string(),
  },
  handler: async (ctx, args) => {
    const category = normalizeModelCategory(args.category);
    if (category === "shipping") {
      const rows = await ctx.db
        .query("mailShipments")
        .withIndex("by_user_updated", (q) => q.eq("userId", args.userId))
        .order("desc")
        .take(25);
      return rows.map((row) => ({
        id: row._id,
        category,
        merchant: row.merchant,
        carrier: row.carrier,
        trackingNumber: row.trackingNumber,
        orderId: row.orderId,
        itemSummary: row.itemSummary,
        status: row.status,
        updatedAt: row.updatedAt,
      }));
    }
    if (category === "bookings") {
      const rows = await ctx.db
        .query("mailBookings")
        .withIndex("by_user_updated", (q) => q.eq("userId", args.userId))
        .order("desc")
        .take(25);
      return rows.map((row) => ({
        id: row._id,
        category,
        provider: row.provider,
        title: row.title,
        bookingCategory: row.category,
        confirmationNumber: row.confirmationNumber,
        bookingCode: row.bookingCode,
        location: row.location,
        startTime: row.startTime,
        status: row.status ?? "booking",
        updatedAt: row.updatedAt,
      }));
    }
    if (category === "meetings_events") {
      const rows = await ctx.db
        .query("mailMeetingsEvents")
        .withIndex("by_user_updated", (q) => q.eq("userId", args.userId))
        .order("desc")
        .take(25);
      return rows.map((row) => ({
        id: row._id,
        category,
        provider: row.provider,
        title: row.title,
        location: row.location,
        startTime: row.startTime,
        endTime: row.endTime,
        status: row.status,
        updatedAt: row.updatedAt,
      }));
    }
    if (category === "invoice") {
      const rows = await ctx.db
        .query("mailInvoices")
        .withIndex("by_user_updated", (q) => q.eq("userId", args.userId))
        .order("desc")
        .take(25);
      return rows.map((row) => ({
        id: row._id,
        category,
        vendor: row.vendor,
        invoiceNumber: row.invoiceNumber,
        amount: row.amount,
        currency: row.currency,
        status: row.status,
        updatedAt: row.updatedAt,
      }));
    }
    return [];
  },
});

export const applyModelAnalysis = internalMutation({
  args: {
    gmailMessageId: v.id("gmailMessages"),
    model: v.string(),
    source: v.optional(v.string()),
    analysis: v.object({
      category: v.string(),
      confidence: v.optional(v.number()),
      reason: v.optional(v.string()),
      decisiveSignals: v.optional(v.array(v.string())),
      possibleAlternativeCategories: v.optional(v.array(v.string())),
      suggestedCategory: v.optional(v.string()),
      notificationType: v.optional(v.string()),
      accountEmail: v.optional(v.string()),
      serviceName: v.optional(v.string()),
      code: v.optional(v.string()),
      url: v.optional(v.string()),
      ipAddress: v.optional(v.string()),
      location: v.optional(v.string()),
      device: v.optional(v.string()),
      app: v.optional(v.string()),
      companyName: v.optional(v.string()),
      ticketId: v.optional(v.string()),
      status: v.optional(v.string()),
      merchant: v.optional(v.string()),
      orderNumber: v.optional(v.string()),
      itemSummary: v.optional(v.string()),
      imageUrl: v.optional(v.string()),
      carrier: v.optional(v.string()),
      trackingNumber: v.optional(v.string()),
      trackingUrl: v.optional(v.string()),
      vendor: v.optional(v.string()),
      invoiceNumber: v.optional(v.string()),
      amount: v.optional(v.number()),
      currency: v.optional(v.string()),
      nextPaymentDueAt: v.optional(v.string()),
      bookingCategory: v.optional(v.string()),
      provider: v.optional(v.string()),
      confirmationNumber: v.optional(v.string()),
      bookingCode: v.optional(v.string()),
      bookingUrl: v.optional(v.string()),
      qrCodeUrl: v.optional(v.string()),
      ticketUrl: v.optional(v.string()),
      title: v.optional(v.string()),
      startTime: v.optional(v.string()),
      endTime: v.optional(v.string()),
      occurredAt: v.optional(v.string()),
      missingButExpectedFields: v.optional(v.array(v.string())),
      mergeTargetId: v.optional(v.string()),
      mergeDecisionReason: v.optional(v.string()),
      mergeConfidence: v.optional(v.number()),
    }),
  },
  handler: async (ctx, args) => {
    const message = await ctx.db.get(args.gmailMessageId);
    if (!message) {
      return null;
    }

    await clearMessageAnalysis(ctx, message._id);

    let category = normalizeModelCategoryWithRequiredFields(args.analysis);
    if (
      (args.analysis.startTime || args.analysis.bookingCategory) &&
      (category === "purchase" ||
        category === "shipping" ||
        category === "subscription" ||
        category === "invoice" ||
        category === "unknown")
    ) {
      category = isPaidBookingMessage(message.subject ?? "", messageText(message), args.analysis)
        ? "bookings"
        : "meetings_events";
    }
    const signalText = messageSignalText(message);
    const fullText = messageText(message);
    if (category === "subscription" && isPromotionalBroadcastOnly(message, fullText, args.analysis)) {
      category = "promotions";
    }
    if (
      (category === "invoice" || category === "purchase") &&
      isSubscriptionMessage(message.subject ?? "", fullText, args.analysis)
    ) {
      category = "subscription";
    }
    if (
      category === "support" &&
      !args.analysis.ticketId &&
      !isSupportMessage(message.subject ?? "", signalText, null)
    ) {
      category = "unknown";
    }
    if (category === "security_notifications" && !isSecurityNotification(message.subject ?? "", signalText, args.analysis)) {
      category = "notifications";
    }
    const now = Date.now();
    const base = {
      userId: message.userId,
      gmailMessageId: message._id,
      googleAccountId: message.googleAccountId,
      providerMessageId: message.providerMessageId,
      createdAt: now,
      updatedAt: now,
    };
    const imageUrls = extractImageUrls(message.bodyHtml);

    await ctx.db.insert("mailClassifications", {
      userId: message.userId,
      gmailMessageId: message._id,
      googleAccountId: message.googleAccountId,
      providerMessageId: message.providerMessageId,
      providerThreadId: message.providerThreadId,
      category,
      confidence: clampConfidence(args.analysis.confidence ?? 0.65),
      source: args.source ?? "model",
      model: args.model,
      reason: args.analysis.reason,
      createdAt: now,
      updatedAt: now,
    });

    if (category === "security_code" && args.analysis.code) {
      await ctx.db.insert("mailSecurityCodes", {
        ...base,
        serviceName: args.analysis.serviceName,
        code: args.analysis.code,
      });
    } else if (category === "security_notifications") {
      await ctx.db.insert("mailSecurityNotifications", {
        ...base,
        notificationType: args.analysis.notificationType ?? inferSecurityNotificationType(message.subject ?? "", fullText),
        serviceName: args.analysis.serviceName,
        accountEmail: args.analysis.accountEmail,
        url: args.analysis.url,
        ipAddress: args.analysis.ipAddress,
        location: args.analysis.location,
        device: args.analysis.device,
        app: args.analysis.app,
        occurredAt: parseModelTimestamp(args.analysis.occurredAt),
        status: args.analysis.status ?? "unknown",
      });
    } else if (category === "notifications") {
      await ctx.db.insert("mailNotifications", {
        ...base,
        notificationType: args.analysis.notificationType ?? "account_notification",
        serviceName: args.analysis.serviceName,
        title: args.analysis.title ?? message.subject,
        status: args.analysis.status ?? "unknown",
        url: args.analysis.url,
        occurredAt: parseModelTimestamp(args.analysis.occurredAt),
      });
    } else if (category === "support") {
      const companyName = (args.analysis.companyName ?? args.analysis.serviceName ?? displaySender(message.from)) || "Unknown";
      const ticketId = args.analysis.ticketId;
      const supportThreadId = await upsertSupportThread(ctx, {
        userId: message.userId,
        companyName,
        ticketId: ticketId ?? null,
        threadKey: normalizedEntityKey(companyName, ticketId ?? message.providerThreadId),
        subject: message.subject ?? args.analysis.title ?? "",
        status: args.analysis.status ?? "unknown",
        latestGmailMessageId: message._id,
        now,
      });
      await ctx.db.insert("mailSupportMessages", {
        ...base,
        supportThreadId,
        companyName,
        ticketId,
        status: args.analysis.status ?? "unknown",
      });
    } else if (category === "purchase" || category === "shipping") {
      const merchant = (args.analysis.merchant ?? displaySender(message.from)) || "Unknown";
      if (category === "shipping") {
        const existingShipmentOrderId = await existingShipmentOrderIdForCandidate(ctx, {
          mergeTargetId: args.analysis.mergeTargetId,
          userId: message.userId,
          merchant,
          carrier: args.analysis.carrier,
          trackingNumber: args.analysis.trackingNumber,
          trackingUrl: args.analysis.trackingUrl ?? args.analysis.url,
          itemSummary: args.analysis.itemSummary ?? args.analysis.title,
        });
        const orderId =
          existingShipmentOrderId ??
          (await upsertOrder(ctx, {
            userId: message.userId,
            merchant,
            orderNumber: args.analysis.orderNumber ?? null,
            itemSummary: args.analysis.itemSummary ?? args.analysis.title ?? null,
            imageUrl: bestImageUrl(args.analysis.imageUrl, imageUrls),
            status: normalizedPurchaseStatus(category, args.analysis.status),
            latestGmailMessageId: message._id,
            now,
          }));
        const shipmentId = await upsertShipment(ctx, {
          mergeTargetId: args.analysis.mergeTargetId,
          userId: message.userId,
          gmailMessageId: message._id,
          googleAccountId: message.googleAccountId,
          providerMessageId: message.providerMessageId,
          orderId,
          merchant,
          carrier: args.analysis.carrier,
          trackingNumber: args.analysis.trackingNumber,
          trackingUrl: args.analysis.trackingUrl ?? args.analysis.url,
          itemSummary: args.analysis.itemSummary ?? args.analysis.title,
          imageUrl: bestImageUrl(args.analysis.imageUrl, imageUrls),
          status: args.analysis.status ?? "unknown",
          now,
        });
        await ctx.db.insert("mailShipmentMessages", {
          ...base,
          shipmentId,
          status: args.analysis.status ?? "unknown",
          trackingNumber: args.analysis.trackingNumber,
          trackingUrl: args.analysis.trackingUrl ?? args.analysis.url,
        });
      } else {
        await upsertOrder(ctx, {
          userId: message.userId,
          merchant,
          orderNumber: args.analysis.orderNumber ?? null,
          itemSummary: args.analysis.itemSummary ?? args.analysis.title ?? null,
          imageUrl: bestImageUrl(args.analysis.imageUrl, imageUrls),
          status: normalizedPurchaseStatus(category, args.analysis.status),
          latestGmailMessageId: message._id,
          now,
        });
      }
    } else if (category === "subscription") {
      const provider =
        (args.analysis.provider ??
          args.analysis.merchant ??
          args.analysis.vendor ??
          args.analysis.serviceName ??
          displaySender(message.from)) ||
        "Unknown";
      const itemSummary = args.analysis.itemSummary ?? args.analysis.title ?? subscriptionItemFromText(provider, fullText);
      const status = normalizedSubscriptionStatus(args.analysis.status);
      const nextPaymentDueAt = parseModelTimestamp(args.analysis.nextPaymentDueAt);
      const subscriptionId = await upsertSubscription(ctx, {
        userId: message.userId,
        provider,
        itemSummary,
        imageUrl: bestImageUrl(args.analysis.imageUrl, imageUrls),
        amount: args.analysis.amount,
        currency: args.analysis.currency,
        nextPaymentDueAt,
        status,
        latestGmailMessageId: message._id,
        now,
      });
      await ctx.db.insert("mailSubscriptionMessages", {
        ...base,
        subscriptionId,
        status,
        amount: args.analysis.amount,
        currency: args.analysis.currency,
        nextPaymentDueAt,
      });
    } else if (category === "invoice") {
      const vendor = (args.analysis.vendor ?? displaySender(message.from)) || "Unknown";
      const invoiceId = await upsertInvoice(ctx, {
        mergeTargetId: args.analysis.mergeTargetId,
        userId: message.userId,
        gmailMessageId: message._id,
        googleAccountId: message.googleAccountId,
        providerMessageId: message.providerMessageId,
        vendor,
        invoiceNumber: args.analysis.invoiceNumber,
        amount: args.analysis.amount,
        currency: args.analysis.currency,
        status: args.analysis.status ?? "unknown",
        now,
      });
      await ctx.db.insert("mailInvoiceMessages", {
        ...base,
        invoiceId,
        amount: args.analysis.amount,
        currency: args.analysis.currency,
        status: args.analysis.status ?? "unknown",
      });
    } else if (category === "bookings") {
      const startTime = parseModelTimestamp(args.analysis.startTime);
      const endTime = parseModelTimestamp(args.analysis.endTime);
      const status = normalizedBookingStatus(args.analysis.status, message.subject ?? "", fullText);
      const title = args.analysis.title ?? message.subject;
      const provider = bookingProviderForDisplay(args.analysis.provider ?? args.analysis.serviceName ?? displaySender(message.from), title);
      const bookingId = await upsertBooking(ctx, {
        mergeTargetId: args.analysis.mergeTargetId,
        userId: message.userId,
        gmailMessageId: message._id,
        googleAccountId: message.googleAccountId,
        providerMessageId: message.providerMessageId,
        category: args.analysis.bookingCategory ?? "booking",
        provider,
        confirmationNumber: args.analysis.confirmationNumber ?? args.analysis.orderNumber,
        bookingCode: args.analysis.bookingCode,
        bookingUrl: args.analysis.bookingUrl ?? args.analysis.url,
        qrCodeUrl: args.analysis.qrCodeUrl,
        ticketUrl: args.analysis.ticketUrl,
        amount: args.analysis.amount,
        currency: args.analysis.currency,
        title,
        location: args.analysis.location,
        startTime,
        endTime,
        status,
        calendarRelevant: true,
        now,
      });
      await ctx.db.insert("mailBookingMessages", {
        ...base,
        bookingId,
        status,
      });
    } else if (category === "meetings_events") {
      const startTime = parseModelTimestamp(args.analysis.startTime);
      const endTime = parseModelTimestamp(args.analysis.endTime);
      const title = args.analysis.title ?? message.subject ?? "Event";
      const meetingEventId = await upsertMeetingEvent(ctx, {
        mergeTargetId: args.analysis.mergeTargetId,
        userId: message.userId,
        gmailMessageId: message._id,
        googleAccountId: message.googleAccountId,
        providerMessageId: message.providerMessageId,
        source: "email",
        provider: args.analysis.provider ?? args.analysis.serviceName,
        eventKey: normalizedEntityKey(
          args.analysis.provider ?? displaySender(message.from) ?? "event",
          [title, args.analysis.location, startTime?.toString()]
            .filter((value): value is string => typeof value === "string" && value.length > 0)
            .join(":"),
        ),
        title,
        location: args.analysis.location,
        url: args.analysis.url,
        startTime,
        endTime,
        status: args.analysis.status ?? "scheduled",
        latestGmailMessageId: message._id,
        now,
      });
      await ctx.db.insert("mailMeetingEventMessages", {
        ...base,
        meetingEventId,
        status: args.analysis.status ?? "scheduled",
      });
    }

    return { category };
  },
});

export const clearAllAnalysisForDev = internalMutation({
  args: {},
  handler: async (ctx) => {
    const tableNames = [
      "mailClassifications",
      "mailSecurityCodes",
      "mailSecurityNotifications",
      "mailNotifications",
      "mailSupportMessages",
      "mailSupportThreads",
      "mailShipmentMessages",
      "mailShipments",
      "mailOrders",
      "mailSubscriptions",
      "mailSubscriptionMessages",
      "mailInvoiceMessages",
      "mailInvoices",
      "mailBookingMessages",
      "mailBookings",
      "mailMeetingEventMessages",
      "mailMeetingsEvents",
    ] as const;

    const deleted: Record<string, number> = {};
    for (const tableName of tableNames) {
      const rows = await ctx.db.query(tableName).collect();
      deleted[tableName] = rows.length;
      for (const row of rows) {
        await ctx.db.delete(row._id);
      }
    }
    return deleted;
  },
});

export const analysisSummaryForDev = internalQuery({
  args: {
    limit: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const limit = args.limit ?? 50;
    const newestMessages = await ctx.db.query("gmailMessages").withIndex("by_internal_date").order("desc").take(limit);
    const newestMessageIds = new Set(newestMessages.map((message) => message._id));
    const classifications = await ctx.db.query("mailClassifications").collect();
    const counts: Record<string, number> = {};
    let classifiedNewestCount = 0;
    for (const classification of classifications) {
      counts[classification.category] = (counts[classification.category] ?? 0) + 1;
      if (newestMessageIds.has(classification.gmailMessageId)) {
        classifiedNewestCount += 1;
      }
    }

    const redHillMessages = newestMessages.filter((message) =>
      [message.from, message.subject, message.snippet, message.bodyText].some((value) =>
        value?.toLowerCase().includes("red hill truffle"),
      ),
    );
    const redHillRows = [];
    for (const message of redHillMessages) {
      const classification = await latestClassificationForMessage(ctx, message._id);
      const bookingRows = new Map<Id<"mailBookings">, Doc<"mailBookings">>();
      const directBookings = await ctx.db
        .query("mailBookings")
        .withIndex("by_message", (q) => q.eq("gmailMessageId", message._id))
        .collect();
      for (const booking of directBookings) {
        bookingRows.set(booking._id, booking);
      }
      const bookingSources = await ctx.db
        .query("mailBookingMessages")
        .withIndex("by_message", (q) => q.eq("gmailMessageId", message._id))
        .collect();
      for (const source of bookingSources) {
        const booking = await ctx.db.get(source.bookingId);
        if (booking) {
          bookingRows.set(booking._id, booking);
        }
      }
      redHillRows.push({
        gmailMessageId: message._id,
        subject: message.subject,
        internalDate: message.internalDate,
        category: classification?.category,
        bookings: [...bookingRows.values()].map((booking) => ({
          title: booking.title,
          category: booking.category,
          provider: booking.provider,
          confirmationNumber: booking.confirmationNumber,
          location: booking.location,
          startTime: booking.startTime,
          endTime: booking.endTime,
        })),
      });
    }

    return {
      counts,
      totalClassifications: classifications.length,
      newestRequested: newestMessages.length,
      classifiedNewestCount,
      missingNewestCount: Math.max(0, newestMessages.length - classifiedNewestCount),
      newestEmailDate: newestMessages[0]?.internalDate,
      oldestEmailDate: newestMessages.at(-1)?.internalDate,
      orders: (await ctx.db.query("mailOrders").order("desc").take(12)).map((order) => ({
        merchant: order.merchant,
        orderNumber: order.orderNumber,
        itemSummary: order.itemSummary,
        imageUrl: order.imageUrl,
        status: order.status,
      })),
      shipments: (await ctx.db.query("mailShipments").order("desc").take(12)).map((shipment) => ({
        merchant: shipment.merchant,
        carrier: shipment.carrier,
        trackingNumber: shipment.trackingNumber,
        itemSummary: shipment.itemSummary,
        imageUrl: shipment.imageUrl,
        status: shipment.status,
      })),
      invoices: (await ctx.db.query("mailInvoices").order("desc").take(12)).map((invoice) => ({
        vendor: invoice.vendor,
        invoiceNumber: invoice.invoiceNumber,
        amount: invoice.amount,
        currency: invoice.currency,
        status: invoice.status,
      })),
      subscriptions: (await ctx.db.query("mailSubscriptions").order("desc").take(12)).map((subscription) => ({
        provider: subscription.provider,
        itemSummary: subscription.itemSummary,
        amount: subscription.amount,
        currency: subscription.currency,
        nextPaymentDueAt: subscription.nextPaymentDueAt,
        status: subscription.status,
      })),
      redHillRows,
    };
  },
});

async function latestClassificationForMessage(ctx: QueryCtx, gmailMessageId: Id<"gmailMessages">) {
  const rows = await ctx.db
    .query("mailClassifications")
    .withIndex("by_message_and_category", (q) => q.eq("gmailMessageId", gmailMessageId))
    .collect();
  return rows.sort((lhs, rhs) => rhs.updatedAt - lhs.updatedAt)[0] ?? null;
}

async function clearMessageAnalysis(ctx: MutationCtx, gmailMessageId: Id<"gmailMessages">) {
  const classifications = await ctx.db
    .query("mailClassifications")
    .withIndex("by_message_and_category", (q) => q.eq("gmailMessageId", gmailMessageId))
    .collect();
  for (const row of classifications) {
    await ctx.db.delete(row._id);
  }

  const tableNames = [
    "mailSecurityCodes",
    "mailSecurityNotifications",
    "mailNotifications",
    "mailSupportMessages",
    "mailSubscriptionMessages",
  ] as const;

  for (const tableName of tableNames) {
    const rows = await ctx.db
      .query(tableName)
      .withIndex("by_message", (q) => q.eq("gmailMessageId", gmailMessageId))
      .collect();
    for (const row of rows) {
      await ctx.db.delete(row._id);
    }
  }

  await clearShipmentSourceForMessage(ctx, gmailMessageId);
  await clearInvoiceSourceForMessage(ctx, gmailMessageId);
  await clearBookingSourceForMessage(ctx, gmailMessageId);
  await clearMeetingEventSourceForMessage(ctx, gmailMessageId);

  const aggregateTableNames = ["mailSupportThreads", "mailOrders", "mailSubscriptions"] as const;
  for (const tableName of aggregateTableNames) {
    const rows = await ctx.db
      .query(tableName)
      .withIndex("by_latest_message", (q) => q.eq("latestGmailMessageId", gmailMessageId))
      .collect();
    for (const row of rows) {
      await ctx.db.delete(row._id);
    }
  }
}

async function clearShipmentSourceForMessage(ctx: MutationCtx, gmailMessageId: Id<"gmailMessages">) {
  const sourceRows = await ctx.db
    .query("mailShipmentMessages")
    .withIndex("by_message", (q) => q.eq("gmailMessageId", gmailMessageId))
    .collect();
  const shipmentIds = new Set(sourceRows.map((row) => row.shipmentId));
  for (const row of sourceRows) {
    await ctx.db.delete(row._id);
  }
  for (const shipmentId of shipmentIds) {
    const shipment = await ctx.db.get(shipmentId);
    if (!shipment) continue;
    const remaining = await ctx.db
      .query("mailShipmentMessages")
      .withIndex("by_shipment", (q) => q.eq("shipmentId", shipmentId))
      .collect();
    if (remaining.length === 0) {
      await ctx.db.delete(shipmentId);
      continue;
    }
    const latest = latestSourceRow(remaining);
    await ctx.db.patch(shipmentId, {
      gmailMessageId: latest.gmailMessageId,
      googleAccountId: latest.googleAccountId,
      providerMessageId: latest.providerMessageId,
      trackingNumber: latest.trackingNumber ?? shipment.trackingNumber,
      trackingUrl: latest.trackingUrl ?? shipment.trackingUrl,
      status: preferStatus(latest.status, shipment.status, shipmentStatusRankForMerge),
      latestGmailMessageId: latest.gmailMessageId,
      updatedAt: latest.updatedAt,
    });
  }
}

async function clearInvoiceSourceForMessage(ctx: MutationCtx, gmailMessageId: Id<"gmailMessages">) {
  const sourceRows = await ctx.db
    .query("mailInvoiceMessages")
    .withIndex("by_message", (q) => q.eq("gmailMessageId", gmailMessageId))
    .collect();
  const invoiceIds = new Set(sourceRows.map((row) => row.invoiceId));
  for (const row of sourceRows) {
    await ctx.db.delete(row._id);
  }
  for (const invoiceId of invoiceIds) {
    const invoice = await ctx.db.get(invoiceId);
    if (!invoice) continue;
    const remaining = await ctx.db
      .query("mailInvoiceMessages")
      .withIndex("by_invoice", (q) => q.eq("invoiceId", invoiceId))
      .collect();
    if (remaining.length === 0) {
      await ctx.db.delete(invoiceId);
      continue;
    }
    const latest = latestSourceRow(remaining);
    await ctx.db.patch(invoiceId, {
      gmailMessageId: latest.gmailMessageId,
      googleAccountId: latest.googleAccountId,
      providerMessageId: latest.providerMessageId,
      amount: latest.amount ?? invoice.amount,
      currency: latest.currency ?? invoice.currency,
      status: latest.status === "unknown" ? invoice.status : latest.status,
      latestGmailMessageId: latest.gmailMessageId,
      updatedAt: latest.updatedAt,
    });
  }
}

async function clearBookingSourceForMessage(ctx: MutationCtx, gmailMessageId: Id<"gmailMessages">) {
  const sourceRows = await ctx.db
    .query("mailBookingMessages")
    .withIndex("by_message", (q) => q.eq("gmailMessageId", gmailMessageId))
    .collect();
  const bookingIds = new Set(sourceRows.map((row) => row.bookingId));
  for (const row of sourceRows) {
    await ctx.db.delete(row._id);
  }
  for (const bookingId of bookingIds) {
    const booking = await ctx.db.get(bookingId);
    if (!booking) continue;
    const remaining = await ctx.db
      .query("mailBookingMessages")
      .withIndex("by_booking", (q) => q.eq("bookingId", bookingId))
      .collect();
    if (remaining.length === 0) {
      await ctx.db.delete(bookingId);
      continue;
    }
    const latest = latestSourceRow(remaining);
    await ctx.db.patch(bookingId, {
      gmailMessageId: latest.gmailMessageId,
      googleAccountId: latest.googleAccountId,
      providerMessageId: latest.providerMessageId,
      status: preferBookingStatus(latest.status, booking.status),
      latestGmailMessageId: latest.gmailMessageId,
      updatedAt: latest.updatedAt,
    });
  }
}

async function clearMeetingEventSourceForMessage(ctx: MutationCtx, gmailMessageId: Id<"gmailMessages">) {
  const sourceRows = await ctx.db
    .query("mailMeetingEventMessages")
    .withIndex("by_message", (q) => q.eq("gmailMessageId", gmailMessageId))
    .collect();
  const meetingEventIds = new Set(sourceRows.map((row) => row.meetingEventId));
  for (const row of sourceRows) {
    await ctx.db.delete(row._id);
  }
  for (const meetingEventId of meetingEventIds) {
    const event = await ctx.db.get(meetingEventId);
    if (!event) continue;
    const remaining = await ctx.db
      .query("mailMeetingEventMessages")
      .withIndex("by_meeting_event", (q) => q.eq("meetingEventId", meetingEventId))
      .collect();
    if (remaining.length === 0) {
      await ctx.db.delete(meetingEventId);
      continue;
    }
    const latest = latestSourceRow(remaining);
    await ctx.db.patch(meetingEventId, {
      gmailMessageId: latest.gmailMessageId,
      googleAccountId: latest.googleAccountId,
      providerMessageId: latest.providerMessageId,
      status: latest.status === "unknown" ? event.status : latest.status,
      latestGmailMessageId: latest.gmailMessageId,
      updatedAt: latest.updatedAt,
    });
  }
}

function latestSourceRow<T extends { updatedAt: number }>(rows: T[]) {
  return [...rows].sort((lhs, rhs) => rhs.updatedAt - lhs.updatedAt)[0];
}

function messageText(message: MessageDoc) {
  return [message.subject, message.from, message.snippet, message.bodyText]
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
    .join("\n");
}

function messageSignalText(message: MessageDoc) {
  return [message.subject, message.from, message.snippet]
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
    .join("\n")
    .replace(/https?:\/\/\S+/gi, " ");
}

function modelMessageText(message: MessageForModel) {
  return [message.subject, message.from, message.snippet, message.bodyText]
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
    .join("\n");
}

function modelSignalText(message: MessageForModel) {
  return [message.subject, message.from, message.snippet]
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
    .join("\n")
    .replace(/https?:\/\/\S+/gi, " ");
}

function isPromotion(message: MessageDoc, text: string) {
  return (
    message.labelIds.includes("CATEGORY_PROMOTIONS") ||
    /\b(sale|discount|promo|offer|newsletter|limited time|deal|coupon|expiring soon|\d+% off|\$\d+ off)\b/i.test(text)
  );
}

function isFallbackPromotion(message: MessageForModel, text: string) {
  return (
    message.labelIds.includes("CATEGORY_PROMOTIONS") ||
    /\b(sale|discount|promo|offer|newsletter|limited time|deal|coupon|expiring soon|launch gift|changelog|product update|\d+% off|\$\d+ off)\b/i.test(
      text,
    )
  );
}

function isAccountNotificationMessage(message: MessageForModel, text: string) {
  const combined = `${message.subject ?? ""}\n${message.from ?? ""}\n${message.snippet ?? ""}\n${text}`;
  return (
    message.labelIds.includes("CATEGORY_SOCIAL") ||
    /\b(notification|alert|invitation|mentioned you|shared with you|commented|replied|new messages?|account notice|status update)\b/i.test(
      combined,
    )
  );
}

function inferAccountNotificationType(subject: string, text: string) {
  const combined = `${subject}\n${text}`;
  if (/\binvitation\b/i.test(combined)) return "invitation";
  if (/\bnew messages?|messaging\b/i.test(combined)) return "message";
  if (/\bmentioned you\b/i.test(combined)) return "mention";
  if (/\bcommented|replied\b/i.test(combined)) return "reply";
  if (/\bstatus|policy|account notice|account update\b/i.test(combined)) return "account_update";
  return "account_notification";
}

function extractSecurityCode(subject: string, text: string) {
  if (/\b(coupon|promo|discount|sale|\$\d+ off|\d+% off)\b/i.test(`${subject}\n${text}`)) {
    return null;
  }
  if (
    !/\b(verification code|security code|login code|sign[- ]?in code|passcode|otp|one[- ]?time|2fa|two[- ]factor)\b/i.test(
      `${subject}\n${text}`,
    )
  ) {
    return null;
  }
  const match = text.match(/\b(?:code|passcode|otp|pin)?\D{0,24}(\d{3}[- ]?\d{3}|\d{6,8}|[A-Z0-9]{6,10})\b/i);
  return match?.[1]?.replace(/[-\s]/g, "") ?? null;
}

function isSignInAlert(subject: string, text: string) {
  return /\b(new|recent|unusual|suspicious|unknown)?\s*(sign[- ]?in|login|log[- ]?in)\s*(alert|notification|detected|from|to)|new device (sign[- ]?in|login)|was this you/i.test(
    `${subject}\n${text}`,
  );
}

function isPasswordReset(subject: string, text: string) {
  return /\b(password reset|reset your password|change your password|forgot password)\b/i.test(`${subject}\n${text}`);
}

function isSignupVerification(subject: string, text: string) {
  return /\b(verify your email|confirm your email|email verification|activate your account|complete signup|complete sign up)\b/i.test(
    `${subject}\n${text}`,
  );
}

function isSupportMessage(subject: string, text: string, ticketId: string | null) {
  return (
    Boolean(ticketId) ||
    /\b(support request|support ticket|case number|ticket number|request received|we received your request|agent replied|your ticket)\b/i.test(
      `${subject}\n${text}`,
    )
  );
}

function isPurchaseMessage(subject: string, text: string, orderNumber: string | null) {
  return (
    Boolean(orderNumber) ||
    /\b(order confirmation|thanks for your order|your order|order number|order #|receipt for your order)\b/i.test(
      `${subject}\n${text}`,
    )
  );
}

function isShippingMessage(subject: string, text: string, trackingNumber: string | null, trackingUrl: string | null) {
  return (
    Boolean(trackingNumber) ||
    (Boolean(trackingUrl) && /\b(shipped|shipment|tracking|parcel|package|delivery)\b/i.test(`${subject}\n${text}`)) ||
    /\b(shipped|shipment|tracking number|out for delivery|has been delivered|delivery is scheduled|parcel from|package has been delivered|arriving today)\b/i.test(
      `${subject}\n${text}`,
    )
  );
}

function isInvoiceMessage(subject: string, text: string, invoiceNumber: string | null) {
  return Boolean(invoiceNumber) || /\b(invoice|receipt|payment received|billing statement|tax invoice)\b/i.test(`${subject}\n${text}`);
}

function isSubscriptionMessage(
  subject: string,
  text: string,
  analysis: {
    provider?: string;
    merchant?: string;
    vendor?: string;
    itemSummary?: string;
  },
) {
  const combined = `${subject}\n${text}\n${analysis.provider ?? ""}\n${analysis.merchant ?? ""}\n${analysis.vendor ?? ""}\n${analysis.itemSummary ?? ""}`;
  return /\b(subscription|subscribed|renewal|renews|recurring|billing period|next payment|next billing|monthly plan|annual plan|yearly plan|trial ending|membership|repeat delivery|autoship|auto ship|auto-delivery|recurring order|claude pro|claude max|amazon music unlimited)\b/i.test(
    combined,
  );
}

function isPromotionalBroadcastOnly(
  message: MessageDoc,
  text: string,
  analysis: {
    provider?: string;
    merchant?: string;
    vendor?: string;
    itemSummary?: string;
    amount?: number;
    nextPaymentDueAt?: string;
    orderNumber?: string;
  },
) {
  const combined = `${message.subject ?? ""}\n${message.from ?? ""}\n${message.snippet ?? ""}\n${text}`;
  if (!/\b(sale|discount|promo|offer|newsletter|limited time|deal|coupon|launch gift|changelog|product update|\d+% off|\$\d+ off)\b/i.test(combined)) {
    return false;
  }
  if (
    analysis.amount ||
    analysis.nextPaymentDueAt ||
    analysis.orderNumber ||
    isSubscriptionMessage(message.subject ?? "", text, analysis) ||
    isPurchaseMessage(message.subject ?? "", text, analysis.orderNumber ?? null) ||
    isShippingMessage(message.subject ?? "", text, null, null) ||
    isInvoiceMessage(message.subject ?? "", text, null)
  ) {
    return false;
  }
  return true;
}

function isPaidBookingMessage(
  subject: string,
  text: string,
  analysis: {
    confirmationNumber?: string;
    bookingCode?: string;
    bookingUrl?: string;
    ticketUrl?: string;
    qrCodeUrl?: string;
    amount?: number;
  },
) {
  const combined = `${subject}\n${text}`;
  return (
    Boolean(analysis.confirmationNumber || analysis.bookingCode || analysis.bookingUrl || analysis.ticketUrl || analysis.qrCodeUrl || analysis.amount) ||
    /\b(ticket|booking|reservation|confirmation|itinerary|boarding pass|rental|hotel|restaurant|appointment|receipt|paid|payment|order)\b/i.test(
      combined,
    )
  );
}

function isSecurityNotification(
  subject: string,
  text: string,
  analysis: {
    notificationType?: string;
    url?: string;
    ipAddress?: string;
    location?: string;
    device?: string;
    app?: string;
  },
) {
  return (
    Boolean(analysis.notificationType || analysis.url || analysis.ipAddress || analysis.location || analysis.device || analysis.app) ||
    isSignInAlert(subject, text) ||
    isPasswordReset(subject, text) ||
    isSignupVerification(subject, text) ||
    /\b(password changed|security alert|security warning|suspicious|blocked login|account recovery|2fa|mfa|two[- ]?factor)\b/i.test(
      `${subject}\n${text}`,
    )
  );
}

function inferSecurityNotificationType(subject: string, text: string) {
  const combined = `${subject}\n${text}`;
  if (isSignInAlert(subject, text)) return "sign_in_alert";
  if (isPasswordReset(subject, text)) return "password_reset";
  if (isSignupVerification(subject, text)) return "signup_verification";
  if (/\bpassword changed\b/i.test(combined)) return "password_changed";
  if (/\bsuspicious|blocked login|security alert|security warning\b/i.test(combined)) return "security_warning";
  return "security_notification";
}

function subscriptionItemFromText(provider: string, text: string) {
  if (/\bclaude max\b/i.test(text)) {
    return "Claude Max";
  }
  if (/\bclaude pro\b|\banthropic\b/i.test(`${provider}\n${text}`)) {
    return "Claude Pro";
  }
  if (/\bamazon music unlimited\b/i.test(text)) {
    return "Amazon Music Unlimited";
  }
  return provider;
}

function extractRelevantUrl(text: string, keywords: string[]) {
  const urls = [...text.matchAll(/https?:\/\/[^\s<>"')]+/gi)].map((match) => match[0]);
  return urls.find((url) => keywords.some((keyword) => url.toLowerCase().includes(keyword))) ?? null;
}

function extractIpAddress(text: string) {
  return text.match(/\b(?:\d{1,3}\.){3}\d{1,3}\b/)?.[0] ?? null;
}

function extractLabeledValue(text: string, labels: string[]) {
  for (const label of labels) {
    const pattern = new RegExp(`${label}\\s*:?\\s*([^\\n.]{3,80})`, "i");
    const value = text.match(pattern)?.[1]?.trim();
    if (value) {
      return value;
    }
  }
  return undefined;
}

function extractTicketId(subject: string, text: string) {
  return `${subject}\n${text}`.match(/\b(?:ticket|case|request|ref(?:erence)?)\s*#?:?\s*([A-Z0-9][A-Z0-9-]{2,24})\b/i)?.[1] ?? null;
}

function extractOrderNumber(subject: string, text: string) {
  return `${subject}\n${text}`.match(/\b(?:order|purchase)\s*(?:number|no\.?|#)?\s*:?\s*([A-Z0-9][A-Z0-9-]{4,40})\b/i)?.[1] ?? null;
}

function extractTrackingNumber(text: string) {
  const knownCarrierMatch = text.match(/\b(1Z[0-9A-Z]{16}|[A-Z]{2}\d{9}[A-Z]{2})\b/i)?.[1];
  if (knownCarrierMatch) {
    return knownCarrierMatch;
  }
  return (
    text.match(/\b(?:tracking|shipment|delivery)\s*(?:number|no\.?|#)?\s*:?\s*([A-Z0-9][A-Z0-9-]{8,34})\b/i)?.[1] ??
    null
  );
}

function extractInvoiceNumber(subject: string, text: string) {
  return `${subject}\n${text}`.match(/\b(?:invoice|receipt)\s*(?:number|no\.?|#)?\s*:?\s*([A-Z0-9][A-Z0-9-]{3,32})\b/i)?.[1] ?? null;
}

function extractAmount(text: string) {
  const match = text.match(/\b(USD|AUD|EUR|GBP|\$|A\$|€|£)\s?(\d+(?:,\d{3})*(?:\.\d{2})?)\b/i);
  if (!match) {
    return null;
  }
  const currency = match[1] === "$" ? "USD" : match[1] === "A$" ? "AUD" : match[1];
  return { currency, amount: Number(match[2].replace(/,/g, "")) };
}

function extractSupportStatus(subject: string, text: string) {
  if (/\b(resolved|closed|solved)\b/i.test(`${subject}\n${text}`)) return "resolved";
  if (/\b(waiting|pending|needs your response)\b/i.test(`${subject}\n${text}`)) return "waiting";
  if (/\b(open|received|created)\b/i.test(`${subject}\n${text}`)) return "open";
  return "unknown";
}

function extractShippingStatus(subject: string, text: string) {
  if (/\bdelivered\b/i.test(`${subject}\n${text}`)) return "delivered";
  if (/\bout for delivery\b/i.test(`${subject}\n${text}`)) return "out_for_delivery";
  if (/\bdelayed\b/i.test(`${subject}\n${text}`)) return "delayed";
  if (/\bshipped|in transit\b/i.test(`${subject}\n${text}`)) return "shipped";
  if (/\blabel created\b/i.test(`${subject}\n${text}`)) return "label_created";
  return "unknown";
}

function extractCarrier(text: string) {
  return text.match(/\b(UPS|USPS|FedEx|DHL|Australia Post|AusPost|TNT)\b/i)?.[1];
}

function extractBooking(subject: string, text: string, senderName: string) {
  if (
    !/\b(booking reminder|booking summary|booking extended|new booking|reservation confirmed|itinerary|flight confirmation|hotel confirmation|rental confirmation|calendar invitation|invitation:)\b/i.test(
      `${subject}\n${text}`,
    )
  ) {
    return null;
  }
  const category = /\bflight|boarding|airport\b/i.test(text)
    ? "flight"
    : /\bhotel|check-in|check out\b/i.test(text)
      ? "hotel"
      : /\brental|car hire\b/i.test(text)
        ? "rental"
        : /\bevent|ticket\b/i.test(text)
          ? "event"
          : "booking";
  const confirmationNumber =
    text.match(/\b(?:confirmation|booking|reservation)\s*(?:number|code|#)?\s*:?\s*([A-Z0-9][A-Z0-9-]{4,24})\b/i)?.[1] ??
    undefined;
  return {
    category,
    provider: senderName || undefined,
    confirmationNumber,
    title: subject || undefined,
    location: extractLabeledValue(text, ["location", "venue", "address"]),
  };
}

async function upsertSupportThread(
  ctx: MutationCtx,
  args: {
    userId: Id<"users">;
    companyName: string;
    ticketId: string | null;
    threadKey: string;
    subject: string;
    status: string;
    latestGmailMessageId: Id<"gmailMessages">;
    now: number;
  },
) {
  const existing = await ctx.db
    .query("mailSupportThreads")
    .withIndex("by_user_thread_key", (q) => q.eq("userId", args.userId).eq("threadKey", args.threadKey))
    .unique();
  if (existing) {
    await ctx.db.patch(existing._id, {
      ticketId: args.ticketId ?? existing.ticketId,
      subject: args.subject || existing.subject,
      status: args.status,
      latestGmailMessageId: args.latestGmailMessageId,
      updatedAt: args.now,
    });
    return existing._id;
  }
  return await ctx.db.insert("mailSupportThreads", {
    userId: args.userId,
    companyName: args.companyName,
    ticketId: args.ticketId ?? undefined,
    threadKey: args.threadKey,
    subject: args.subject,
    status: args.status,
    latestGmailMessageId: args.latestGmailMessageId,
    createdAt: args.now,
    updatedAt: args.now,
  });
}

async function upsertOrder(
  ctx: MutationCtx,
  args: {
    userId: Id<"users">;
    merchant: string;
    orderNumber: string | null;
    itemSummary: string | null;
    imageUrl?: string;
    status: string;
    latestGmailMessageId: Id<"gmailMessages">;
    now: number;
  },
) {
  const orderKey = normalizedEntityKey(args.merchant, args.orderNumber ?? "unknown");
  const existing = await ctx.db
    .query("mailOrders")
    .withIndex("by_user_order_key", (q) => q.eq("userId", args.userId).eq("orderKey", orderKey))
    .unique();
  if (existing) {
    await ctx.db.patch(existing._id, {
      itemSummary: args.itemSummary ?? existing.itemSummary,
      imageUrl: args.imageUrl ?? existing.imageUrl,
      status: args.status === "unknown" ? existing.status : args.status,
      latestGmailMessageId: args.latestGmailMessageId,
      updatedAt: args.now,
    });
    return existing._id;
  }
  return await ctx.db.insert("mailOrders", {
    userId: args.userId,
    merchant: args.merchant,
    orderNumber: args.orderNumber ?? undefined,
    orderKey,
    itemSummary: args.itemSummary ?? undefined,
    imageUrl: args.imageUrl,
    status: args.status,
    latestGmailMessageId: args.latestGmailMessageId,
    createdAt: args.now,
    updatedAt: args.now,
  });
}

async function upsertShipment(
  ctx: MutationCtx,
  args: {
    mergeTargetId?: string;
    userId: Id<"users">;
    gmailMessageId: Id<"gmailMessages">;
    googleAccountId: Id<"googleAccounts">;
    providerMessageId: string;
    orderId?: Id<"mailOrders">;
    merchant?: string;
    carrier?: string;
    trackingNumber?: string;
    trackingUrl?: string;
    itemSummary?: string;
    imageUrl?: string;
    status: string;
    now: number;
  },
) {
  const shipmentKey = shipmentEntityKey(args);
  const existingByModel = args.mergeTargetId ? await ctx.db.get(args.mergeTargetId as Id<"mailShipments">) : null;
  const existing =
    existingByModel?.userId === args.userId && canMergeShipmentEntity(existingByModel, args)
      ? existingByModel
      : await ctx.db
          .query("mailShipments")
          .withIndex("by_user_shipment_key", (q) => q.eq("userId", args.userId).eq("shipmentKey", shipmentKey))
          .unique();

  if (existing) {
    await ctx.db.patch(existing._id, {
      gmailMessageId: args.gmailMessageId,
      googleAccountId: args.googleAccountId,
      providerMessageId: args.providerMessageId,
      orderId: existing.orderId ?? args.orderId,
      shipmentKey: existing.shipmentKey ?? shipmentKey,
      merchant: args.merchant ?? existing.merchant,
      carrier: args.carrier ?? existing.carrier,
      trackingNumber: args.trackingNumber ?? existing.trackingNumber,
      trackingUrl: args.trackingUrl ?? existing.trackingUrl,
      itemSummary: args.itemSummary ?? existing.itemSummary,
      imageUrl: args.imageUrl ?? existing.imageUrl,
      status: preferStatus(args.status, existing.status, shipmentStatusRankForMerge),
      latestGmailMessageId: args.gmailMessageId,
      updatedAt: args.now,
    });
    return existing._id;
  }

  return await ctx.db.insert("mailShipments", {
    userId: args.userId,
    gmailMessageId: args.gmailMessageId,
    orderId: args.orderId,
    shipmentKey,
    googleAccountId: args.googleAccountId,
    providerMessageId: args.providerMessageId,
    merchant: args.merchant,
    carrier: args.carrier,
    trackingNumber: args.trackingNumber,
    trackingUrl: args.trackingUrl,
    itemSummary: args.itemSummary,
    imageUrl: args.imageUrl,
    status: args.status,
    latestGmailMessageId: args.gmailMessageId,
    createdAt: args.now,
    updatedAt: args.now,
  });
}

async function existingShipmentOrderIdForCandidate(
  ctx: MutationCtx,
  args: {
    mergeTargetId?: string;
    userId: Id<"users">;
    merchant?: string;
    carrier?: string;
    trackingNumber?: string;
    trackingUrl?: string;
    itemSummary?: string;
  },
) {
  const existingByModel = args.mergeTargetId ? await ctx.db.get(args.mergeTargetId as Id<"mailShipments">) : null;
  if (existingByModel?.userId === args.userId && canMergeShipmentEntity(existingByModel, args)) {
    return existingByModel.orderId;
  }

  const shipmentKey = shipmentEntityKey(args);
  const existingByKey = await ctx.db
    .query("mailShipments")
    .withIndex("by_user_shipment_key", (q) => q.eq("userId", args.userId).eq("shipmentKey", shipmentKey))
    .unique();
  if (existingByKey) {
    return existingByKey.orderId;
  }

  if (args.trackingNumber) {
    const candidates = await ctx.db
      .query("mailShipments")
      .withIndex("by_user_tracking", (q) => q.eq("userId", args.userId).eq("trackingNumber", args.trackingNumber))
      .take(5);
    const matching = candidates.find((candidate) => canMergeShipmentEntity(candidate, args));
    return matching?.orderId;
  }

  return undefined;
}

async function upsertInvoice(
  ctx: MutationCtx,
  args: {
    mergeTargetId?: string;
    userId: Id<"users">;
    gmailMessageId: Id<"gmailMessages">;
    googleAccountId: Id<"googleAccounts">;
    providerMessageId: string;
    vendor: string;
    invoiceNumber?: string;
    amount?: number;
    currency?: string;
    status: string;
    now: number;
  },
) {
  const invoiceKey = invoiceEntityKey(args);
  const existingByModel = args.mergeTargetId ? await ctx.db.get(args.mergeTargetId as Id<"mailInvoices">) : null;
  const existing =
    existingByModel?.userId === args.userId && canMergeInvoiceEntity(existingByModel, args)
      ? existingByModel
      : await ctx.db
          .query("mailInvoices")
          .withIndex("by_user_invoice_key", (q) => q.eq("userId", args.userId).eq("invoiceKey", invoiceKey))
          .unique();

  if (existing) {
    await ctx.db.patch(existing._id, {
      gmailMessageId: args.gmailMessageId,
      googleAccountId: args.googleAccountId,
      providerMessageId: args.providerMessageId,
      vendor: args.vendor || existing.vendor,
      invoiceNumber: args.invoiceNumber ?? existing.invoiceNumber,
      amount: args.amount ?? existing.amount,
      currency: args.currency ?? existing.currency,
      status: args.status === "unknown" ? existing.status : args.status,
      latestGmailMessageId: args.gmailMessageId,
      updatedAt: args.now,
    });
    return existing._id;
  }

  return await ctx.db.insert("mailInvoices", {
    userId: args.userId,
    gmailMessageId: args.gmailMessageId,
    googleAccountId: args.googleAccountId,
    providerMessageId: args.providerMessageId,
    vendor: args.vendor,
    invoiceNumber: args.invoiceNumber,
    invoiceKey,
    amount: args.amount,
    currency: args.currency,
    status: args.status,
    latestGmailMessageId: args.gmailMessageId,
    createdAt: args.now,
    updatedAt: args.now,
  });
}

async function upsertBooking(
  ctx: MutationCtx,
  args: {
    mergeTargetId?: string;
    userId: Id<"users">;
    gmailMessageId: Id<"gmailMessages">;
    googleAccountId: Id<"googleAccounts">;
    providerMessageId: string;
    category: string;
    provider?: string;
    confirmationNumber?: string;
    bookingCode?: string;
    bookingUrl?: string;
    qrCodeUrl?: string;
    ticketUrl?: string;
    amount?: number;
    currency?: string;
    title?: string;
    location?: string;
    startTime?: number;
    endTime?: number;
    status: string;
    calendarRelevant: boolean;
    now: number;
  },
) {
  const bookingKey = bookingEntityKey(args);
  const existingByModel = args.mergeTargetId ? await ctx.db.get(args.mergeTargetId as Id<"mailBookings">) : null;
  const existing =
    existingByModel?.userId === args.userId && canMergeBookingEntity(existingByModel, args)
      ? existingByModel
      : await ctx.db
          .query("mailBookings")
          .withIndex("by_user_booking_key", (q) => q.eq("userId", args.userId).eq("bookingKey", bookingKey))
          .unique();

  if (existing) {
    await ctx.db.patch(existing._id, {
      gmailMessageId: args.gmailMessageId,
      googleAccountId: args.googleAccountId,
      providerMessageId: args.providerMessageId,
      bookingKey: existing.bookingKey ?? bookingKey,
      category: args.category || existing.category,
      provider: args.provider ?? existing.provider,
      confirmationNumber: args.confirmationNumber ?? existing.confirmationNumber,
      bookingCode: args.bookingCode ?? existing.bookingCode,
      bookingUrl: args.bookingUrl ?? existing.bookingUrl,
      qrCodeUrl: args.qrCodeUrl ?? existing.qrCodeUrl,
      ticketUrl: args.ticketUrl ?? existing.ticketUrl,
      amount: args.amount ?? existing.amount,
      currency: args.currency ?? existing.currency,
      title: args.title ?? existing.title,
      location: args.location ?? existing.location,
      startTime: args.startTime ?? existing.startTime,
      endTime: args.endTime ?? existing.endTime,
      status: preferBookingStatus(args.status, existing.status),
      calendarRelevant: existing.calendarRelevant || args.calendarRelevant,
      latestGmailMessageId: args.gmailMessageId,
      updatedAt: args.now,
    });
    return existing._id;
  }

  return await ctx.db.insert("mailBookings", {
    userId: args.userId,
    gmailMessageId: args.gmailMessageId,
    googleAccountId: args.googleAccountId,
    providerMessageId: args.providerMessageId,
    bookingKey,
    category: args.category,
    provider: args.provider,
    confirmationNumber: args.confirmationNumber,
    bookingCode: args.bookingCode,
    bookingUrl: args.bookingUrl,
    qrCodeUrl: args.qrCodeUrl,
    ticketUrl: args.ticketUrl,
    amount: args.amount,
    currency: args.currency,
    title: args.title,
    location: args.location,
    startTime: args.startTime,
    endTime: args.endTime,
    status: args.status,
    calendarRelevant: args.calendarRelevant,
    latestGmailMessageId: args.gmailMessageId,
    createdAt: args.now,
    updatedAt: args.now,
  });
}

async function upsertSubscription(
  ctx: MutationCtx,
  args: {
    userId: Id<"users">;
    provider: string;
    itemSummary: string;
    imageUrl?: string;
    amount?: number;
    currency?: string;
    nextPaymentDueAt?: number;
    status: string;
    latestGmailMessageId: Id<"gmailMessages">;
    now: number;
  },
) {
  const subscriptionKey = subscriptionEntityKey(args.provider, args.itemSummary);
  const existing = await ctx.db
    .query("mailSubscriptions")
    .withIndex("by_user_subscription_key", (q) => q.eq("userId", args.userId).eq("subscriptionKey", subscriptionKey))
    .unique();

  if (existing) {
    await ctx.db.patch(existing._id, {
      provider: args.provider || existing.provider,
      itemSummary: args.itemSummary || existing.itemSummary,
      imageUrl: args.imageUrl ?? existing.imageUrl,
      amount: args.amount ?? existing.amount,
      currency: args.currency ?? existing.currency,
      nextPaymentDueAt: args.nextPaymentDueAt ?? existing.nextPaymentDueAt,
      status: args.status === "unknown" ? existing.status : args.status,
      latestGmailMessageId: args.latestGmailMessageId,
      updatedAt: args.now,
    });
    return existing._id;
  }

  return await ctx.db.insert("mailSubscriptions", {
    userId: args.userId,
    subscriptionKey,
    provider: args.provider,
    itemSummary: args.itemSummary,
    imageUrl: args.imageUrl,
    amount: args.amount,
    currency: args.currency,
    nextPaymentDueAt: args.nextPaymentDueAt,
    status: args.status,
    latestGmailMessageId: args.latestGmailMessageId,
    createdAt: args.now,
    updatedAt: args.now,
  });
}

async function upsertMeetingEvent(
  ctx: MutationCtx,
  args: {
    mergeTargetId?: string;
    userId: Id<"users">;
    gmailMessageId: Id<"gmailMessages">;
    googleAccountId: Id<"googleAccounts">;
    providerMessageId: string;
    source: string;
    provider?: string;
    eventKey: string;
    title?: string;
    location?: string;
    url?: string;
    startTime?: number;
    endTime?: number;
    status: string;
    latestGmailMessageId: Id<"gmailMessages">;
    now: number;
  },
) {
  const existingByModel = args.mergeTargetId ? await ctx.db.get(args.mergeTargetId as Id<"mailMeetingsEvents">) : null;
  const existing =
    existingByModel?.userId === args.userId && canMergeMeetingEventEntity(existingByModel, args)
      ? existingByModel
      : await ctx.db
          .query("mailMeetingsEvents")
          .withIndex("by_user_event_key", (q) => q.eq("userId", args.userId).eq("eventKey", args.eventKey))
          .unique();

  if (existing) {
    await ctx.db.patch(existing._id, {
      gmailMessageId: args.gmailMessageId,
      googleAccountId: args.googleAccountId,
      providerMessageId: args.providerMessageId,
      provider: args.provider ?? existing.provider,
      title: args.title ?? existing.title,
      location: args.location ?? existing.location,
      url: args.url ?? existing.url,
      startTime: args.startTime ?? existing.startTime,
      endTime: args.endTime ?? existing.endTime,
      status: args.status === "unknown" ? existing.status : args.status,
      latestGmailMessageId: args.latestGmailMessageId,
      updatedAt: args.now,
    });
    return existing._id;
  }

  return await ctx.db.insert("mailMeetingsEvents", {
    userId: args.userId,
    gmailMessageId: args.gmailMessageId,
    googleAccountId: args.googleAccountId,
    providerMessageId: args.providerMessageId,
    source: args.source,
    provider: args.provider,
    eventKey: args.eventKey,
    title: args.title,
    location: args.location,
    url: args.url,
    startTime: args.startTime,
    endTime: args.endTime,
    status: args.status,
    latestGmailMessageId: args.latestGmailMessageId,
    createdAt: args.now,
    updatedAt: args.now,
  });
}

function displaySender(from?: string) {
  const raw = from?.trim() ?? "";
  const name = raw.split("<", 1)[0]?.replace(/["']/g, "").trim();
  return name || domainFromEmail(from) || "";
}

function domainFromEmail(from?: string) {
  return from?.match(/@([^>\s]+)/)?.[1]?.toLowerCase();
}

function normalizedEntityKey(prefix: string, value: string) {
  return `${prefix}:${value}`.toLowerCase().replace(/[^a-z0-9]+/g, ":").replace(/^:|:$/g, "");
}

function subscriptionEntityKey(provider: string, itemSummary: string) {
  const providerKey = canonicalCompanyName(provider);
  const itemKey = canonicalSubscriptionItem(providerKey, itemSummary);
  return normalizedEntityKey(providerKey, itemKey);
}

function shipmentEntityKey(args: {
  orderId?: Id<"mailOrders">;
  merchant?: string;
  carrier?: string;
  trackingNumber?: string;
  trackingUrl?: string;
  itemSummary?: string;
}) {
  const trackingUrlKey = canonicalTrackingUrlKey(args.trackingUrl);
  if (trackingUrlKey) {
    return normalizedEntityKey("tracking-url", trackingUrlKey);
  }
  if (args.trackingNumber) {
    return normalizedEntityKey("tracking", args.trackingNumber);
  }
  if (args.orderId) {
    return normalizedEntityKey("order", args.orderId);
  }
  return normalizedEntityKey(args.merchant ?? args.carrier ?? "shipment", canonicalItemSummary(args.itemSummary ?? "unknown"));
}

function invoiceEntityKey(args: {
  vendor: string;
  invoiceNumber?: string;
  amount?: number;
  currency?: string;
}) {
  if (args.invoiceNumber) {
    return normalizedEntityKey(args.vendor, args.invoiceNumber);
  }
  return normalizedEntityKey(args.vendor, [args.currency, args.amount?.toFixed(2)].filter(Boolean).join(":") || "unknown");
}

function bookingEntityKey(args: {
  provider?: string;
  title?: string;
  confirmationNumber?: string;
  bookingCode?: string;
  bookingUrl?: string;
  ticketUrl?: string;
  qrCodeUrl?: string;
  location?: string;
  startTime?: number;
}) {
  const provider = bookingProviderForKey(args.provider, args.title);
  if (args.confirmationNumber) {
    return normalizedEntityKey(provider, args.confirmationNumber);
  }
  if (args.bookingCode) {
    return normalizedEntityKey(provider, args.bookingCode);
  }
  if (args.bookingUrl || args.ticketUrl || args.qrCodeUrl) {
    return normalizedEntityKey(provider, args.bookingUrl ?? args.ticketUrl ?? args.qrCodeUrl ?? "");
  }
  if (isBookingLifecycleTitle(args.title)) {
    return normalizedEntityKey(provider, "booking-lifecycle");
  }
  return normalizedEntityKey(
    provider,
    [args.title, args.location, args.startTime?.toString()].filter((value): value is string => Boolean(value)).join(":") || "unknown",
  );
}

function canonicalTrackingUrlKey(value?: string) {
  if (!value) {
    return null;
  }
  try {
    const url = new URL(value);
    const path = url.pathname.toLowerCase().replace(/\/+$/g, "");
    const shippitMatch = path.match(/\/tracking\/([^/]+)/)?.[1];
    if (shippitMatch) {
      return `${url.hostname.toLowerCase()}/tracking/${shippitMatch}`;
    }
    return `${url.hostname.toLowerCase()}${path}`;
  } catch {
    const match = value.toLowerCase().match(/app\.shippit\.com\/tracking\/([^/?#]+)/)?.[1];
    return match ? `app.shippit.com/tracking/${match}` : null;
  }
}

function canonicalItemSummary(value: string) {
  return value
    .toLowerCase()
    .replace(/\b(quantity|qty|order|shipment|delivery|package|item|items)\b/g, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function preferStatus(candidate: string, current: string, rank: (status: string) => number) {
  if (!candidate || candidate === "unknown") {
    return current;
  }
  if (!current || current === "unknown") {
    return candidate;
  }
  return rank(candidate) >= rank(current) ? candidate : current;
}

function shipmentStatusRankForMerge(status: string) {
  const normalized = normalizedEntityKey("status", status);
  if (normalized.includes("delivered")) return 5;
  if (normalized.includes("out:for:delivery")) return 4;
  if (normalized.includes("on:the:way") || normalized.includes("in:transit") || normalized.includes("shipped")) return 3;
  if (normalized.includes("ordered") || normalized.includes("confirmed")) return 2;
  if (normalized.includes("unknown")) return 0;
  return 1;
}

function canMergeShipmentEntity(
  existing: Doc<"mailShipments">,
  candidate: {
    orderId?: Id<"mailOrders">;
    merchant?: string;
    carrier?: string;
    trackingNumber?: string;
    trackingUrl?: string;
    itemSummary?: string;
  },
) {
  const existingUrlKey = canonicalTrackingUrlKey(existing.trackingUrl);
  const candidateUrlKey = canonicalTrackingUrlKey(candidate.trackingUrl);
  if (existingUrlKey && candidateUrlKey) {
    return existingUrlKey === candidateUrlKey;
  }
  if (existing.trackingNumber && candidate.trackingNumber) {
    return normalizedCompare(existing.trackingNumber, candidate.trackingNumber);
  }
  if (existing.orderId && candidate.orderId) {
    return existing.orderId === candidate.orderId;
  }
  if ((existing.trackingNumber && !candidate.trackingNumber) || (!existing.trackingNumber && candidate.trackingNumber)) {
    return Boolean(existing.orderId && candidate.orderId && existing.orderId === candidate.orderId);
  }
  return sameCompanyish(existing.merchant ?? existing.carrier, candidate.merchant ?? candidate.carrier) &&
    sameItemish(existing.itemSummary, candidate.itemSummary);
}

function canMergeInvoiceEntity(
  existing: Doc<"mailInvoices">,
  candidate: {
    vendor: string;
    invoiceNumber?: string;
    amount?: number;
    currency?: string;
  },
) {
  if (existing.invoiceNumber && candidate.invoiceNumber) {
    return normalizedCompare(existing.invoiceNumber, candidate.invoiceNumber);
  }
  if ((existing.invoiceNumber && !candidate.invoiceNumber) || (!existing.invoiceNumber && candidate.invoiceNumber)) {
    return sameCompanyish(existing.vendor, candidate.vendor) && sameMoney(existing.amount, candidate.amount, existing.currency, candidate.currency);
  }
  return sameCompanyish(existing.vendor, candidate.vendor) && sameMoney(existing.amount, candidate.amount, existing.currency, candidate.currency);
}

function canMergeBookingEntity(
  existing: Doc<"mailBookings">,
  candidate: {
    provider?: string;
    title?: string;
    confirmationNumber?: string;
    bookingCode?: string;
    bookingUrl?: string;
    ticketUrl?: string;
    qrCodeUrl?: string;
    location?: string;
    startTime?: number;
  },
) {
  const existingProvider = bookingProviderForKey(existing.provider, existing.title);
  const candidateProvider = bookingProviderForKey(candidate.provider, candidate.title);
  const existingStrongId = existing.confirmationNumber ?? existing.bookingCode ?? existing.bookingUrl ?? existing.ticketUrl ?? existing.qrCodeUrl;
  const candidateStrongId = candidate.confirmationNumber ?? candidate.bookingCode ?? candidate.bookingUrl ?? candidate.ticketUrl ?? candidate.qrCodeUrl;
  if (existingStrongId && candidateStrongId) {
    return normalizedCompare(existingStrongId, candidateStrongId);
  }
  if (existingStrongId || candidateStrongId) {
    return (
      sameCompanyish(existingProvider, candidateProvider) &&
      sameItemish(existing.title, candidate.title) &&
      sameLocationish(existing.location, candidate.location) &&
      sameTimeish(existing.startTime, candidate.startTime)
    );
  }
  if (sameCompanyish(existingProvider, candidateProvider) && isBookingLifecycleTitle(existing.title) && isBookingLifecycleTitle(candidate.title)) {
    return true;
  }
  return (
    sameCompanyish(existingProvider, candidateProvider) &&
    sameItemish(existing.title, candidate.title) &&
    sameLocationish(existing.location, candidate.location) &&
    sameTimeish(existing.startTime, candidate.startTime)
  );
}

function canMergeMeetingEventEntity(
  existing: Doc<"mailMeetingsEvents">,
  candidate: {
    provider?: string;
    title?: string;
    location?: string;
    startTime?: number;
    endTime?: number;
  },
) {
  return (
    sameTimeish(existing.startTime, candidate.startTime) &&
    (sameItemish(existing.title, candidate.title) || sameLocationish(existing.location, candidate.location)) &&
    (!existing.provider || !candidate.provider || sameCompanyish(existing.provider, candidate.provider))
  );
}

function normalizedCompare(lhs?: string, rhs?: string) {
  return Boolean(lhs && rhs && normalizedLoose(lhs) === normalizedLoose(rhs));
}

function sameCompanyish(lhs?: string, rhs?: string) {
  if (!lhs || !rhs) {
    return false;
  }
  return normalizedLoose(canonicalCompanyName(lhs)) === normalizedLoose(canonicalCompanyName(rhs));
}

function sameItemish(lhs?: string, rhs?: string) {
  if (!lhs || !rhs) {
    return false;
  }
  const left = canonicalItemSummary(lhs);
  const right = canonicalItemSummary(rhs);
  return left === right || left.includes(right) || right.includes(left);
}

function sameLocationish(lhs?: string, rhs?: string) {
  if (!lhs || !rhs) {
    return false;
  }
  const left = normalizedLoose(lhs);
  const right = normalizedLoose(rhs);
  return left === right || left.includes(right) || right.includes(left);
}

function sameTimeish(lhs?: number, rhs?: number) {
  if (!lhs || !rhs) {
    return false;
  }
  return Math.abs(lhs - rhs) <= 2 * 60 * 60 * 1000;
}

function sameMoney(lhsAmount?: number, rhsAmount?: number, lhsCurrency?: string, rhsCurrency?: string) {
  if (lhsAmount === undefined || rhsAmount === undefined) {
    return false;
  }
  if (lhsCurrency && rhsCurrency && normalizedLoose(lhsCurrency) !== normalizedLoose(rhsCurrency)) {
    return false;
  }
  return Math.abs(lhsAmount - rhsAmount) < 0.01;
}

function isBookingLifecycleTitle(value?: string) {
  return Boolean(
    value &&
      /\b(booking expired|booking cancelled|booking canceled|booking summary|booking reminder|new booking information|new booking|expiration warning)\b/i.test(
        value,
      ),
  );
}

function bookingProviderForDisplay(provider?: string, title?: string) {
  return bookingLifecycleProviderFromTitle(title) ?? provider;
}

function bookingProviderForKey(provider?: string, title?: string) {
  return bookingProviderForDisplay(provider, title) ?? "booking";
}

function bookingLifecycleProviderFromTitle(value?: string) {
  if (!value || !isBookingLifecycleTitle(value)) {
    return undefined;
  }
  const match = value.match(
    /^\s*(.+?)\s*(?:-|:|\||\u2013|\u2014)\s*(booking expired|booking cancelled|booking canceled|booking summary|booking reminder|new booking information|new booking|expiration warning)\b/i,
  );
  const provider = match?.[1]?.trim();
  if (!provider) {
    return undefined;
  }
  const normalized = normalizedLoose(provider);
  if (!normalized || /\b(booking|reservation|confirmation|reminder|warning)\b/i.test(normalized)) {
    return undefined;
  }
  return provider;
}

function normalizedLoose(value: string) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function canonicalCompanyName(value: string) {
  return value
    .toLowerCase()
    .replace(/\b(pbc|inc|incorporated|llc|ltd|limited|pty|corp|corporation|company|co|roaster|roasters)\b/g, " ")
    .replace(/\b(receipts?|billing|payments?|support|team)\b/g, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

function canonicalSubscriptionItem(providerKey: string, value: string) {
  const normalized = value.toLowerCase();
  if (providerKey.includes("anthropic") || /\bclaude\b|\banthropic\b/.test(normalized)) {
    return normalized.includes("max") ? "claude max" : "claude pro";
  }
  return normalized
    .replace(/\b(subscription|monthly|annual|yearly|plan|renewal|receipt|invoice|payment)\b/g, " ")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

type MessageForModel = {
  _id: Id<"gmailMessages">;
  userId: Id<"users">;
  googleAccountId: Id<"googleAccounts">;
  providerMessageId: string;
  providerThreadId: string;
  from?: string;
  to?: string;
  subject?: string;
  labelIds: string[];
  snippet?: string;
  bodyText?: string;
  imageUrls: string[];
  internalDate?: number;
};

async function analyzeWithOpenRouterPipeline(apiKey: string, message: MessageForModel): Promise<ModelEmailAnalysis> {
  const classification = await classifyCategoryWithOpenRouter(apiKey, message);
  let category = classification.category;
  let extraction = await extractCategoryDetailsWithOpenRouter(apiKey, message, category);
  if (extraction.suggestedCategory && extraction.suggestedCategory !== category) {
    category = extraction.suggestedCategory;
    extraction = await extractCategoryDetailsWithOpenRouter(apiKey, message, category);
  }

  let analysis = mergeModelAnalyses(classification, extraction, category);
  const missingFields = missingFieldsForCategory(analysis.category, analysis);
  if (missingFields.length > 0) {
    const verification = await verifyMissingFieldsWithOpenRouter(apiKey, message, analysis, missingFields);
    if (verification.decision === "recategorize" && verification.correctedCategory && verification.correctedCategory !== analysis.category) {
      const correctedExtraction = await extractCategoryDetailsWithOpenRouter(apiKey, message, verification.correctedCategory);
      analysis = mergeModelAnalyses(analysis, correctedExtraction, verification.correctedCategory);
    } else {
      analysis = mergeModelAnalyses(analysis, verification.fields ?? {}, analysis.category);
      analysis.missingButExpectedFields = verification.missingFields ?? missingFields;
    }
    analysis.reason = verification.reason ?? analysis.reason;
  }

  return analysis;
}

async function maybeResolveMergeTargetWithOpenRouter(
  ctx: ActionCtx,
  apiKey: string,
  message: MessageForModel,
  analysis: ModelEmailAnalysis,
): Promise<ModelEmailAnalysis> {
  const category = normalizeModelCategory(analysis.category);
  if (!isModelMergeCategory(category)) {
    return analysis;
  }

  const candidates: Array<Record<string, unknown>> = await ctx.runQuery(internal.mailAnalysis.mergeCandidatesForModel, {
    userId: message.userId,
    category,
  });
  if (candidates.length === 0) {
    return analysis;
  }

  try {
    const decision = await mergeDecisionWithOpenRouter(apiKey, message, analysis, candidates);
    const targetId = decision.targetId;
    if (
      decision.decision === "update_existing" &&
      targetId &&
      decision.confidence >= 0.55 &&
      candidates.some((candidate) => candidate.id === targetId)
    ) {
      return {
        ...analysis,
        mergeTargetId: targetId,
        mergeDecisionReason: decision.reason,
        mergeConfidence: decision.confidence,
      };
    }
    return {
      ...analysis,
      mergeDecisionReason: decision.reason,
      mergeConfidence: decision.confidence,
    };
  } catch (error) {
    return {
      ...analysis,
      mergeDecisionReason: `Merge resolver skipped: ${errorMessage(error)}`,
    };
  }
}

async function classifyCategoryWithOpenRouter(apiKey: string, message: MessageForModel): Promise<ModelEmailAnalysis> {
  const content = await openRouterJson(apiKey, [
    {
      role: "system",
      content: `${categoryDefinitionPrompt()}

Choose the single best category. This is classification only: do not extract all fields yet.
Return compact JSON only.`,
    },
    {
      role: "user",
      content: JSON.stringify({
        task: "classify_email",
        allowedCategories: allowedCategories(),
        returnSchema: {
          category: "one allowed category",
          confidence: "0 to 1",
          reason: "short reason",
          decisiveSignals: ["short evidence strings"],
          possibleAlternativeCategories: ["optional close alternatives"],
        },
        email: emailPayload(message),
      }),
    },
  ]);
  return normalizeModelAnalysis(content);
}

async function mergeDecisionWithOpenRouter(
  apiKey: string,
  message: MessageForModel,
  analysis: ModelEmailAnalysis,
  candidates: Array<Record<string, unknown>>,
) {
  const content = await openRouterJson(apiKey, [
    {
      role: "system",
      content: `You decide whether a newly extracted email entity updates an existing dashboard entity.

Return compact JSON only. The targetId must be exactly one supplied candidate id, or null.
Prefer update_existing when stable identifiers match, such as tracking number, order number, booking code, confirmation number, invoice number, same provider/title/date/location, or clearly same item lifecycle.
Choose new_entity when identifiers conflict, dates differ materially, item/provider differs, or the relationship is only broad/same merchant.
Do not invent missing identifiers.`,
    },
    {
      role: "user",
      content: JSON.stringify({
        task: "resolve_mail_entity_merge",
        returnSchema: {
          decision: "update_existing|new_entity",
          targetId: "candidate id when updating, otherwise null",
          confidence: "0 to 1",
          reason: "short reason",
        },
        email: emailPayload(message),
        extractedEntity: mergeEntityPayload(analysis),
        existingCandidates: candidates,
      }),
    },
  ]);
  const object = isRecord(content) ? content : {};
  const decision = stringValue(object.decision);
  return {
    decision: decision === "update_existing" ? "update_existing" : "new_entity",
    targetId: stringValue(object.targetId),
    confidence: numberValue(object.confidence) ?? 0,
    reason: stringValue(object.reason),
  };
}

async function extractCategoryDetailsWithOpenRouter(
  apiKey: string,
  message: MessageForModel,
  category: ModelCategory,
): Promise<ModelEmailAnalysis> {
  if (category === "spam" || category === "promotions" || category === "unknown") {
    return { category, confidence: 0.85 };
  }

  const content = await openRouterJson(apiKey, [
    {
      role: "system",
      content: `${categoryExtractionPrompt(category)}

Extract only facts that are explicitly present in the email. If the email does not actually fit ${category}, return suggestedCategory with the better category. Return compact JSON only.`,
    },
    {
      role: "user",
      content: JSON.stringify({
        task: "extract_category_details",
        category,
        allowedCategories: allowedCategories(),
        returnSchema: extractionSchemaForCategory(category),
        email: emailPayload(message),
      }),
    },
  ]);
  return normalizeModelAnalysis({ category, ...(isRecord(content) ? content : {}) });
}

async function verifyMissingFieldsWithOpenRouter(
  apiKey: string,
  message: MessageForModel,
  analysis: ModelEmailAnalysis,
  missingFields: string[],
): Promise<{
  decision: "update_fields" | "category_confirmed_missing_data" | "recategorize";
  correctedCategory?: ModelCategory;
  fields?: Partial<ModelEmailAnalysis>;
  missingFields?: string[];
  reason?: string;
}> {
  const content = await openRouterJson(apiKey, [
    {
      role: "system",
      content: `${categoryDefinitionPrompt()}

You verify missing extraction fields for one already-classified email.
Return compact JSON only. Do not invent facts. If missing fields are not present, confirm that. If the category is wrong, recategorize once.`,
    },
    {
      role: "user",
      content: JSON.stringify({
        task: "verify_missing_fields",
        currentAnalysis: analysis,
        missingFields,
        allowedCategories: allowedCategories(),
        returnSchema: {
          decision: "update_fields|category_confirmed_missing_data|recategorize",
          correctedCategory: "one allowed category when recategorizing",
          fields: "object with only corrected or newly found fields",
          missingFields: "fields that are genuinely absent",
          reason: "short reason",
        },
        email: emailPayload(message),
      }),
    },
  ]);
  const object = isRecord(content) ? content : {};
  const decision = stringValue(object.decision);
  const fields = isRecord(object.fields) ? normalizeModelAnalysis({ category: analysis.category, ...object.fields }) : undefined;
  const missing = stringArrayValue(object.missingFields) ?? [];
  const correctedCategory = stringValue(object.correctedCategory);
  return {
    decision:
      decision === "recategorize" || decision === "category_confirmed_missing_data" || decision === "update_fields"
        ? decision
        : "category_confirmed_missing_data",
    correctedCategory: correctedCategory ? normalizeModelCategory(correctedCategory) : undefined,
    fields,
    missingFields: missing.length > 0 ? missing : undefined,
    reason: stringValue(object.reason),
  };
}

async function openRouterJson(apiKey: string, messages: Array<{ role: "system" | "user"; content: string }>): Promise<unknown> {
  const first = await openRouterContent(apiKey, messages, true);
  const parsedFirst = parseJsonObject(first);
  if (parsedFirst) {
    return parsedFirst;
  }

  const retry = await openRouterContent(apiKey, messages, false);
  const parsedRetry = parseJsonObject(retry);
  return parsedRetry ?? {};
}

async function openRouterContent(
  apiKey: string,
  messages: Array<{ role: "system" | "user"; content: string }>,
  useJsonMode: boolean,
) {
  const model = process.env.OPENROUTER_MODEL || DEFAULT_OPENROUTER_MODEL;
  const timeoutMs = openRouterTimeoutMs();
  const requestBody: Record<string, unknown> = {
    model,
    messages,
    reasoning: {
      effort: process.env.OPENROUTER_REASONING_EFFORT || DEFAULT_OPENROUTER_REASONING_EFFORT,
      exclude: true,
    },
    temperature: 0,
  };
  if (useJsonMode) {
    requestBody.response_format = { type: "json_object" };
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  let response: Response;
  try {
    response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
        "HTTP-Referer": "browser://dashboard",
        "X-Title": "Browser Mail Analyzer",
      },
      body: JSON.stringify(requestBody),
      signal: controller.signal,
    });
  } catch (error) {
    if (controller.signal.aborted) {
      throw new Error(`OpenRouter mail analysis timed out after ${timeoutMs}ms.`);
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }

  if (!response.ok) {
    const body = await response.text();
    throw new Error(`OpenRouter mail analysis failed: ${response.status} ${body.slice(0, 240)}`);
  }

  const json = (await response.json()) as {
    choices?: Array<{ message?: { content?: unknown; reasoning?: unknown } }>;
  };
  const content = json.choices?.[0]?.message?.content;
  if (typeof content === "string") {
    return content;
  }
  if (Array.isArray(content)) {
    return content
      .map((part) => (isRecord(part) ? stringValue(part.text) ?? stringValue(part.content) ?? "" : ""))
      .join("\n")
      .trim();
  }
  const reasoning = json.choices?.[0]?.message?.reasoning;
  return typeof reasoning === "string" ? reasoning : "";
}

function openRouterTimeoutMs() {
  const value = Number(process.env.OPENROUTER_TIMEOUT_MS);
  return Number.isFinite(value) && value >= 5_000 ? value : DEFAULT_OPENROUTER_TIMEOUT_MS;
}

function parseJsonObject(content: string) {
  const trimmed = content.trim();
  if (!trimmed) {
    return null;
  }
  const fenced = trimmed.match(/```(?:json)?\s*([\s\S]*?)```/i)?.[1]?.trim();
  const candidate = fenced ?? trimmed.match(/\{[\s\S]*\}/)?.[0] ?? trimmed;
  try {
    return JSON.parse(candidate);
  } catch {
    return null;
  }
}

function gmailLabelBaselineAnalysis(message: MessageForModel): ModelEmailAnalysis | null {
  if (message.labelIds.includes("SPAM")) {
    return {
      category: "spam",
      confidence: 1,
      reason: "Gmail labeled this message as spam.",
      decisiveSignals: ["SPAM"],
    };
  }
  if (message.labelIds.includes("CATEGORY_PROMOTIONS")) {
    return {
      category: "promotions",
      confidence: 1,
      reason: "Gmail labeled this message as a promotion.",
      decisiveSignals: ["CATEGORY_PROMOTIONS"],
    };
  }
  return null;
}

function fallbackAnalysisForModelFailure(message: MessageForModel, failure: string): ModelEmailAnalysis {
  const subject = message.subject ?? "";
  const fullText = modelMessageText(message);
  const signalText = modelSignalText(message);
  const sender = displaySender(message.from) || domainFromEmail(message.from) || "Unknown";
  const reason = `Model analysis failed before completion: ${failure}. Classified with deterministic fallback.`;

  const code = extractSecurityCode(subject, fullText);
  if (code) {
    return {
      category: "security_code",
      confidence: 0.7,
      reason,
      serviceName: sender,
      code,
      url: extractRelevantUrl(fullText, ["verify", "login", "signin", "sign-in", "account"]) ?? undefined,
    };
  }

  if (isSecurityNotification(subject, signalText, {})) {
    return {
      category: "security_notifications",
      confidence: 0.65,
      reason,
      notificationType: inferSecurityNotificationType(subject, signalText),
      serviceName: sender,
      url:
        extractRelevantUrl(fullText, ["security", "account", "password", "login", "signin", "sign-in", "verify"]) ??
        undefined,
      ipAddress: extractIpAddress(fullText) ?? undefined,
      location: extractLabeledValue(fullText, ["location"]),
      device: extractLabeledValue(fullText, ["device"]),
      app: extractLabeledValue(fullText, ["app", "application"]),
      status: "unknown",
    };
  }

  const trackingNumber = extractTrackingNumber(fullText);
  const trackingUrl = extractRelevantUrl(fullText, ["track", "tracking", "shipment", "delivery", "parcel"]);
  if (isShippingMessage(subject, fullText, trackingNumber, trackingUrl)) {
    return {
      category: "shipping",
      confidence: 0.65,
      reason,
      merchant: sender,
      carrier: extractCarrier(fullText),
      trackingNumber: trackingNumber ?? undefined,
      trackingUrl: trackingUrl ?? undefined,
      itemSummary: subject || undefined,
      status: extractShippingStatus(subject, fullText),
    };
  }

  if (isSubscriptionMessage(subject, fullText, { provider: sender })) {
    const amount = extractAmount(fullText);
    return {
      category: "subscription",
      confidence: 0.65,
      reason,
      provider: sender,
      itemSummary: subscriptionItemFromText(sender, fullText),
      amount: amount?.amount,
      currency: amount?.currency,
      status: /cancel/i.test(fullText) ? "cancelled" : /fail|declin|overdue/i.test(fullText) ? "payment_failed" : "unknown",
    };
  }

  const invoiceNumber = extractInvoiceNumber(subject, fullText);
  if (isInvoiceMessage(subject, fullText, invoiceNumber)) {
    const amount = extractAmount(fullText);
    return {
      category: "invoice",
      confidence: 0.65,
      reason,
      vendor: sender,
      invoiceNumber: invoiceNumber ?? undefined,
      amount: amount?.amount,
      currency: amount?.currency,
      status: "unknown",
    };
  }

  const booking = extractBooking(subject, fullText, sender);
  if (booking && isPaidBookingMessage(subject, fullText, booking)) {
    return {
      category: "bookings",
      confidence: 0.6,
      reason,
      provider: booking.provider,
      bookingCategory: booking.category,
      confirmationNumber: booking.confirmationNumber,
      title: booking.title,
      location: booking.location,
      bookingUrl: extractRelevantUrl(fullText, ["booking", "reservation", "ticket", "event"]) ?? undefined,
    };
  }

  const orderNumber = extractOrderNumber(subject, fullText);
  if (isPurchaseMessage(subject, fullText, orderNumber)) {
    const amount = extractAmount(fullText);
    return {
      category: "purchase",
      confidence: 0.6,
      reason,
      merchant: sender,
      orderNumber: orderNumber ?? undefined,
      itemSummary: subject || undefined,
      amount: amount?.amount,
      currency: amount?.currency,
      status: "unknown",
    };
  }

  const ticketId = extractTicketId(subject, fullText);
  if (isSupportMessage(subject, signalText, ticketId)) {
    return {
      category: "support",
      confidence: 0.6,
      reason,
      companyName: sender,
      ticketId: ticketId ?? undefined,
      status: extractSupportStatus(subject, fullText),
    };
  }

  if (isAccountNotificationMessage(message, fullText)) {
    return {
      category: "notifications",
      confidence: 0.6,
      reason,
      notificationType: inferAccountNotificationType(subject, fullText),
      serviceName: sender,
      title: subject || message.snippet,
      url: extractRelevantUrl(fullText, ["notification", "invitation", "message", "account", "profile", "network"]) ?? undefined,
      status: /\bunread|new\b/i.test(fullText) ? "new" : "unknown",
    };
  }

  if (isFallbackPromotion(message, fullText)) {
    return {
      category: "promotions",
      confidence: 0.6,
      reason,
    };
  }

  return {
    category: "unknown",
    confidence: 0.2,
    reason,
  };
}

function allowedCategories() {
  return [
    "promotions",
    "spam",
    "security_code",
    "security_notifications",
    "notifications",
    "subscription",
    "purchase",
    "shipping",
    "invoice",
    "bookings",
    "meetings_events",
    "support",
    "unknown",
  ];
}

function isModelMergeCategory(category: ModelCategory) {
  return category === "shipping" || category === "bookings" || category === "meetings_events" || category === "invoice";
}

function mergeEntityPayload(analysis: ModelEmailAnalysis) {
  return {
    category: analysis.category,
    merchant: analysis.merchant,
    vendor: analysis.vendor,
    provider: analysis.provider,
    serviceName: analysis.serviceName,
    carrier: analysis.carrier,
    trackingNumber: analysis.trackingNumber,
    orderNumber: analysis.orderNumber,
    itemSummary: analysis.itemSummary,
    status: analysis.status,
    invoiceNumber: analysis.invoiceNumber,
    amount: analysis.amount,
    currency: analysis.currency,
    bookingCategory: analysis.bookingCategory,
    confirmationNumber: analysis.confirmationNumber,
    bookingCode: analysis.bookingCode,
    title: analysis.title,
    location: analysis.location,
    startTime: analysis.startTime,
    endTime: analysis.endTime,
    url: analysis.url,
  };
}

function emailPayload(message: MessageForModel) {
  return {
    from: message.from,
    to: message.to,
    subject: message.subject,
    labelIds: message.labelIds,
    snippet: message.snippet,
    bodyText: message.bodyText,
    candidateImageUrls: message.imageUrls,
    internalDate: message.internalDate,
  };
}

function categoryDefinitionPrompt() {
  return `You classify emails for a private personal mail dashboard.

Choose based on what the email means for the user, not keyword matches alone.
Do not click, follow, or validate links. Dates must be ISO-8601 strings when extractable.

Categories:

spam:
Unwanted, deceptive, suspicious, phishing, scam, malware, fake prize, fake invoice, fake account warning, or clearly irrelevant unsolicited mail.

promotions:
Mass-broadcast marketing, newsletters, product announcements, launch announcements, discounts, coupons, sales, changelogs, feature announcements, surveys, community updates, event marketing, or brand content where there is no evidence of a personal transaction, account action, booking, delivery, invoice, support ticket, or active subscription change.

security_code:
A one-time login, verification, OTP, 2FA, MFA, or security code email containing the actual code.

security_notifications:
Sign-in alerts, signup verification, password reset/recovery, account security warnings, password changed notices, suspicious access, blocked login, or other security-sensitive account notifications. OTP/code emails with an actual code are security_code instead.

notifications:
Non-security account notices that are not marketing, such as service/account status, policy, storage, product/account operational notices, usage limits, or admin notices.

subscription:
An email about a subscription, membership, recurring plan, recurring billing, renewal, trial, cancellation, pause, plan change, payment failure for a subscription, or automated recurring order/repeat delivery that the user has, just started, is renewing, is cancelling, or is being charged for. This includes physical repeat deliveries and autoship orders.

purchase:
A one-time order, purchase confirmation, receipt, or transaction that is not recurring, not a subscription, not primarily a shipment update, and not a booking/event.

shipping:
A parcel, delivery, tracking, shipment, courier, delivered, out-for-delivery, delayed, or pickup notification for a physical item. Prefer shipping over purchase when the email's main purpose is delivery status.

invoice:
An invoice, bill, receipt, payment confirmation, payment failure, tax invoice, statement, refund, charge, payout, or payment request. If the payment is clearly for a subscription, choose subscription instead.

bookings:
Paid or reserved booking-style items: travel, rentals, restaurants, ticketed events, paid experiences, appointments, confirmations, or reservations. Extract booking code, QR URL, ticket/link, confirmation number, location, and event date when present.

meetings_events:
Unpaid calendar-like meetings, friend/work activities, invitations, work meetings, social plans, and non-transactional events.

support:
A customer support ticket, case, request, helpdesk thread, status update, agent reply, support confirmation, or ticket resolution.

unknown:
Use only when the email cannot be confidently assigned.

Precedence rules:
- Gmail SPAM and CATEGORY_PROMOTIONS are handled before the model and should not reach this prompt.
- Repeat delivery, autoship, recurring order, renewal, membership, or plan is subscription, not purchase.
- Tracking number or delivery lifecycle status is shipping unless the main purpose is only order confirmation.
- Paid/reserved/ticketed/confirmation events are bookings.
- Non-paid work/friend/calendar invitations are meetings_events.
- Launch gifts, discounts, changelogs, newsletters, product updates, or sales are promotions if no personal actionable signal exists.
- Do not invent facts.`;
}

function categoryExtractionPrompt(category: ModelCategory) {
  const common =
    "Return fields from the schema. Use null or omit fields that are absent. Include suggestedCategory only when the selected category is clearly wrong.";
  const prompts: Record<ModelCategory, string> = {
    spam: common,
    promotions: common,
    unknown: common,
    security_code:
      `${common} Extract OTP/security code facts. Required focus: serviceName, code, accountEmail, url, occurredAt, missingButExpectedFields.`,
    security_notifications:
      `${common} Extract security notification facts. Include notificationType such as sign_in_alert, signup_verification, password_reset, password_changed, suspicious_login, security_warning. Extract serviceName, accountEmail, url, ipAddress, location, device, app, occurredAt, status.`,
    notifications:
      `${common} Extract non-security account notification facts. Include notificationType, serviceName, title, status, url, occurredAt.`,
    subscription:
      `${common} Extract subscription facts including provider, itemSummary, status, amount, currency, nextPaymentDueAt, orderNumber for repeat deliveries, imageUrl, url. Subscriptions include recurring software, memberships, trials, renewals, cancellations, failed subscription payments, and physical repeat deliveries/autoship.`,
    purchase:
      `${common} Extract one-time purchase facts including merchant, orderNumber, itemSummary as the purchased item/items, amount, currency, imageUrl, status, url. Do not use purchase for recurring/repeat delivery or shipment status.`,
    shipping:
      `${common} Extract shipping facts including merchant, carrier, trackingNumber, trackingUrl, orderNumber, itemSummary, imageUrl, status, url, startTime or endTime only if explicitly delivery-related.`,
    invoice:
      `${common} Extract invoice/payment facts including vendor, invoiceNumber, amount, currency, status, url, occurredAt, nextPaymentDueAt when payment is due.`,
    bookings:
      `${common} Extract paid/reserved booking facts including provider, title, bookingCategory, confirmationNumber, bookingCode, bookingUrl, qrCodeUrl, ticketUrl, location, startTime, endTime, amount, currency, status, url.`,
    meetings_events:
      `${common} Extract unpaid meeting/event facts including provider, title, location, startTime, endTime, url, status.`,
    support:
      `${common} Extract support thread facts including companyName, ticketId, status, title, url, occurredAt.`,
  };
  return prompts[category];
}

function extractionSchemaForCategory(category: ModelCategory) {
  const base = {
    category,
    confidence: "0 to 1",
    reason: "short reason",
    suggestedCategory: "optional one allowed category if this email does not actually fit the requested category",
    missingButExpectedFields: ["fields expected for the category but absent"],
  };
  if (category === "security_code") {
    return { ...base, serviceName: null, accountEmail: null, code: null, url: null, occurredAt: null };
  }
  if (category === "security_notifications") {
    return {
      ...base,
      notificationType: null,
      serviceName: null,
      accountEmail: null,
      url: null,
      ipAddress: null,
      location: null,
      device: null,
      app: null,
      occurredAt: null,
      status: null,
    };
  }
  if (category === "notifications") {
    return { ...base, notificationType: null, serviceName: null, title: null, status: null, url: null, occurredAt: null };
  }
  if (category === "subscription") {
    return {
      ...base,
      provider: null,
      itemSummary: null,
      status: null,
      amount: null,
      currency: null,
      nextPaymentDueAt: null,
      orderNumber: null,
      imageUrl: null,
      url: null,
    };
  }
  if (category === "purchase") {
    return { ...base, merchant: null, orderNumber: null, itemSummary: null, amount: null, currency: null, imageUrl: null, status: null, url: null };
  }
  if (category === "shipping") {
    return { ...base, merchant: null, carrier: null, trackingNumber: null, trackingUrl: null, orderNumber: null, itemSummary: null, imageUrl: null, status: null };
  }
  if (category === "invoice") {
    return { ...base, vendor: null, invoiceNumber: null, amount: null, currency: null, status: null, url: null, occurredAt: null, nextPaymentDueAt: null };
  }
  if (category === "bookings") {
    return {
      ...base,
      provider: null,
      title: null,
      bookingCategory: null,
      confirmationNumber: null,
      bookingCode: null,
      bookingUrl: null,
      qrCodeUrl: null,
      ticketUrl: null,
      location: null,
      startTime: null,
      endTime: null,
      amount: null,
      currency: null,
      status: null,
    };
  }
  if (category === "meetings_events") {
    return { ...base, provider: null, title: null, location: null, startTime: null, endTime: null, url: null, status: null };
  }
  if (category === "support") {
    return { ...base, companyName: null, ticketId: null, status: null, title: null, url: null, occurredAt: null };
  }
  return base;
}

function mergeModelAnalyses(
  first: Partial<ModelEmailAnalysis>,
  second: Partial<ModelEmailAnalysis>,
  category: ModelCategory,
): ModelEmailAnalysis {
  return {
    ...first,
    ...second,
    category,
    confidence: second.confidence ?? first.confidence,
    reason: second.reason ?? first.reason,
    decisiveSignals: second.decisiveSignals ?? first.decisiveSignals,
    possibleAlternativeCategories: second.possibleAlternativeCategories ?? first.possibleAlternativeCategories,
  };
}

function missingFieldsForCategory(category: ModelCategory, analysis: ModelEmailAnalysis) {
  const missing: string[] = [];
  if (category === "security_code" && !analysis.code) missing.push("code");
  if (category === "security_notifications" && !analysis.notificationType) missing.push("notificationType");
  if (category === "subscription") {
    if (!analysis.provider && !analysis.serviceName && !analysis.merchant) missing.push("provider");
    if (!analysis.itemSummary && !analysis.title) missing.push("itemSummary");
  }
  if (category === "purchase") {
    if (!analysis.merchant) missing.push("merchant");
    if (!analysis.itemSummary && !analysis.title) missing.push("itemSummary");
  }
  if (category === "shipping" && !analysis.trackingNumber && !analysis.trackingUrl && !analysis.status) {
    missing.push("trackingNumber", "trackingUrl", "status");
  }
  if (category === "invoice" && !analysis.invoiceNumber && !analysis.amount && !analysis.status) {
    missing.push("invoiceNumber", "amount", "status");
  }
  if (category === "bookings") {
    if (!analysis.title) missing.push("title");
    if (!analysis.confirmationNumber && !analysis.bookingCode && !analysis.bookingUrl && !analysis.ticketUrl && !analysis.qrCodeUrl) {
      missing.push("confirmationNumber", "bookingCode", "bookingUrl");
    }
    if (!analysis.startTime) missing.push("startTime");
  }
  if (category === "meetings_events") {
    if (!analysis.title) missing.push("title");
    if (!analysis.startTime) missing.push("startTime");
  }
  if (category === "support" && !analysis.companyName && !analysis.ticketId) {
    missing.push("companyName", "ticketId");
  }
  return [...new Set(missing)];
}

function normalizeModelAnalysis(value: unknown): ModelEmailAnalysis {
  const object = isRecord(value) ? value : {};
  const category = normalizeModelCategory(stringValue(object.category));
  const suggestedCategory = stringValue(object.suggestedCategory);
  return {
    category,
    confidence: numberValue(object.confidence),
    reason: stringValue(object.reason),
    decisiveSignals: stringArrayValue(object.decisiveSignals),
    possibleAlternativeCategories: stringArrayValue(object.possibleAlternativeCategories),
    suggestedCategory: suggestedCategory ? normalizeModelCategory(suggestedCategory) : undefined,
    notificationType: stringValue(object.notificationType),
    accountEmail: stringValue(object.accountEmail),
    serviceName: stringValue(object.serviceName),
    code: stringValue(object.code),
    url: stringValue(object.url),
    ipAddress: stringValue(object.ipAddress),
    location: stringValue(object.location),
    device: stringValue(object.device),
    app: stringValue(object.app),
    companyName: stringValue(object.companyName),
    ticketId: stringValue(object.ticketId),
    status: stringValue(object.status),
    merchant: stringValue(object.merchant),
    orderNumber: stringValue(object.orderNumber),
    itemSummary: stringValue(object.itemSummary),
    imageUrl: stringValue(object.imageUrl),
    carrier: stringValue(object.carrier),
    trackingNumber: stringValue(object.trackingNumber),
    trackingUrl: stringValue(object.trackingUrl),
    vendor: stringValue(object.vendor),
    invoiceNumber: stringValue(object.invoiceNumber),
    amount: numberValue(object.amount),
    currency: stringValue(object.currency),
    nextPaymentDueAt: stringValue(object.nextPaymentDueAt),
    bookingCategory: stringValue(object.bookingCategory),
    provider: stringValue(object.provider),
    confirmationNumber: stringValue(object.confirmationNumber),
    bookingCode: stringValue(object.bookingCode),
    bookingUrl: stringValue(object.bookingUrl),
    qrCodeUrl: stringValue(object.qrCodeUrl),
    ticketUrl: stringValue(object.ticketUrl),
    title: stringValue(object.title),
    startTime: stringValue(object.startTime),
    endTime: stringValue(object.endTime),
    occurredAt: stringValue(object.occurredAt),
    missingButExpectedFields: stringArrayValue(object.missingButExpectedFields),
    mergeTargetId: stringValue(object.mergeTargetId),
    mergeDecisionReason: stringValue(object.mergeDecisionReason),
    mergeConfidence: numberValue(object.mergeConfidence),
  };
}

function normalizeModelCategory(value?: string): ModelCategory {
  const normalized = value?.trim().toLowerCase() as ModelCategory | "promotion" | "sign_in_alert" | "signup_verification" | "password_reset" | "booking" | "booking_event" | undefined;
  if (normalized === "promotion") {
    return "promotions";
  }
  if (normalized === "sign_in_alert" || normalized === "signup_verification" || normalized === "password_reset") {
    return "security_notifications";
  }
  if (normalized === "booking" || normalized === "booking_event") {
    return "bookings";
  }
  if (
    normalized === "spam" ||
    normalized === "promotions" ||
    normalized === "security_code" ||
    normalized === "security_notifications" ||
    normalized === "notifications" ||
    normalized === "support" ||
    normalized === "purchase" ||
    normalized === "shipping" ||
    normalized === "subscription" ||
    normalized === "invoice" ||
    normalized === "bookings" ||
    normalized === "meetings_events" ||
    normalized === "unknown"
  ) {
    return normalized;
  }
  return "unknown";
}

function normalizeModelCategoryWithRequiredFields(analysis: {
  category?: string;
  code?: string;
  url?: string;
  trackingNumber?: string;
  trackingUrl?: string;
  status?: string;
  invoiceNumber?: string;
  amount?: number;
  provider?: string;
  merchant?: string;
  itemSummary?: string;
  title?: string;
  notificationType?: string;
  confirmationNumber?: string;
  bookingCode?: string;
  bookingUrl?: string;
  qrCodeUrl?: string;
  ticketUrl?: string;
  startTime?: string;
}): ModelCategory {
  const category = normalizeModelCategory(analysis.category);
  if (category === "security_code" && !analysis.code) {
    return "unknown";
  }
  if (category === "shipping" && !analysis.trackingNumber && !analysis.trackingUrl && !analysis.status) {
    return "unknown";
  }
  if (category === "invoice" && !analysis.invoiceNumber && !analysis.amount && !analysis.status) {
    return "unknown";
  }
  return category;
}

function truncateForModel(value?: string) {
  if (!value || value.length <= 20_000) {
    return value;
  }
  return `${value.slice(0, 20_000)}\n\n[Email body truncated before model classification.]`;
}

function clampConfidence(value: number) {
  if (!Number.isFinite(value)) {
    return 0.65;
  }
  return Math.max(0, Math.min(1, value));
}

function parseModelTimestamp(value?: string) {
  if (!value) {
    return undefined;
  }
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? timestamp : undefined;
}

function normalizedPurchaseStatus(category: ModelCategory, value?: string) {
  const normalized = value?.trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
  if (normalized && normalized !== "unknown") {
    return normalized;
  }
  return category === "purchase" ? "ordered" : "unknown";
}

function normalizedSubscriptionStatus(value?: string) {
  const normalized = value?.trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
  return normalized && normalized !== "unknown" ? normalized : "active";
}

function normalizedBookingStatus(value: string | undefined, subject: string, text: string) {
  const combined = `${value ?? ""}\n${subject}\n${text}`;
  if (/\bcancell?ed\b/i.test(combined)) return "cancelled";
  if (/\bexpired\b/i.test(combined)) return "expired";
  if (/\bexpiration warning|expiring|expires soon\b/i.test(combined)) return "expiring";
  if (/\bconfirmed|confirmation|is confirmed\b/i.test(combined)) return "confirmed";
  if (/\breminder\b/i.test(combined)) return "reminder";
  if (/\bnew booking|booking information\b/i.test(combined)) return "new";
  if (/\bsummary\b/i.test(combined)) return "summary";
  const normalized = value?.trim().toLowerCase().replace(/[^a-z0-9]+/g, "_").replace(/^_|_$/g, "");
  return normalized && normalized !== "unknown" && normalized !== "booking" ? normalized : "booking";
}

function preferBookingStatus(candidate: string, current?: string) {
  if (!current || current === "booking" || current === "unknown") {
    return candidate;
  }
  if (!candidate || candidate === "booking" || candidate === "unknown") {
    return current;
  }
  return bookingStatusRank(candidate) >= bookingStatusRank(current) ? candidate : current;
}

function bookingStatusRank(value: string) {
  const normalized = normalizedEntityKey("status", value);
  if (normalized.includes("cancelled")) return 6;
  if (normalized.includes("expired")) return 5;
  if (normalized.includes("expiring")) return 4;
  if (normalized.includes("confirmed")) return 3;
  if (normalized.includes("new")) return 2;
  if (normalized.includes("reminder") || normalized.includes("summary")) return 1;
  return 0;
}

function extractImageUrls(bodyHtml?: string) {
  if (!bodyHtml) {
    return [];
  }
  const urls = [...bodyHtml.matchAll(/<img\b[^>]*\bsrc=["']([^"']+)["'][^>]*>/gi)]
    .map((match) => decodeHtmlAttribute(match[1]))
    .filter((url) => isUsefulEmailImageUrl(url));
  return [...new Set(urls)].slice(0, 12);
}

function bestImageUrl(value: string | undefined, candidates: string[]) {
  if (value && isUsefulEmailImageUrl(value)) {
    return value;
  }
  return candidates[0];
}

function isUsefulEmailImageUrl(value?: string) {
  if (!value || !/^https?:\/\//i.test(value)) {
    return false;
  }
  const lower = value.toLowerCase();
  return !/(pixel|tracking|track|beacon|spacer|transparent|openrate|analytics|logo|icon|avatar|social|facebook|instagram|twitter|x\.com)/i.test(
    lower,
  );
}

function decodeHtmlAttribute(value: string) {
  return value
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringValue(value: unknown) {
  return typeof value === "string" && value.trim().length > 0 ? value.trim() : undefined;
}

function numberValue(value: unknown) {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function errorMessage(error: unknown) {
  if (error instanceof Error && error.message.trim().length > 0) {
    return error.message.slice(0, 240);
  }
  if (typeof error === "string" && error.trim().length > 0) {
    return error.trim().slice(0, 240);
  }
  return "Unknown model error";
}

function stringArrayValue(value: unknown) {
  if (!Array.isArray(value)) {
    return undefined;
  }
  const strings = value.filter((item): item is string => typeof item === "string" && item.trim().length > 0).map((item) => item.trim());
  return strings.length > 0 ? strings : undefined;
}
