import { v } from "convex/values";
import { mutation, query, QueryCtx, MutationCtx } from "./_generated/server";
import { Id } from "./_generated/dataModel";

type AuthenticatedCtx = QueryCtx | MutationCtx;
const SESSION_DURATION_MS = 30 * 24 * 60 * 60 * 1000;

export async function getCurrentUser(
  ctx: AuthenticatedCtx,
  sessionToken: string,
): Promise<Id<"users">> {
  const tokenHash = await sha256(sessionToken);
  const session = await ctx.db
    .query("userSessions")
    .withIndex("by_token_hash", (q) => q.eq("tokenHash", tokenHash))
    .unique();

  if (!session || session.expiresAt < Date.now()) {
    throw new Error("Authentication required.");
  }

  return session.userId;
}

export const register = mutation({
  args: {
    username: v.string(),
    password: v.string(),
  },
  handler: async (ctx, args) => {
    const username = normalizeUsername(args.username);
    validatePassword(args.password);

    const existing = await ctx.db
      .query("users")
      .withIndex("by_username", (q) => q.eq("username", username))
      .unique();
    if (existing) {
      throw new Error("Username is already taken.");
    }

    const now = Date.now();
    const passwordSalt = randomToken(24);
    const passwordHash = await passwordDigest(passwordSalt, args.password);
    const userId = await ctx.db.insert("users", {
      username,
      passwordHash,
      passwordSalt,
      createdAt: now,
      updatedAt: now,
    });

    const sessionToken = await createSession(ctx, userId);
    return { sessionToken, username };
  },
});

export const login = mutation({
  args: {
    username: v.string(),
    password: v.string(),
  },
  handler: async (ctx, args) => {
    const username = normalizeUsername(args.username);
    const user = await ctx.db
      .query("users")
      .withIndex("by_username", (q) => q.eq("username", username))
      .unique();

    if (!user) {
      throw new Error("Invalid username or password.");
    }

    const passwordHash = await passwordDigest(user.passwordSalt, args.password);
    if (passwordHash !== user.passwordHash) {
      throw new Error("Invalid username or password.");
    }

    const sessionToken = await createSession(ctx, user._id);
    return { sessionToken, username: user.username };
  },
});

export const logout = mutation({
  args: {
    sessionToken: v.string(),
  },
  handler: async (ctx, args) => {
    const tokenHash = await sha256(args.sessionToken);
    const session = await ctx.db
      .query("userSessions")
      .withIndex("by_token_hash", (q) => q.eq("tokenHash", tokenHash))
      .unique();
    if (session) {
      await ctx.db.delete(session._id);
    }
  },
});

export const me = query({
  args: {
    sessionToken: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const user = await ctx.db.get(userId);
    return user ? { username: user.username } : null;
  },
});

export const validateSession = mutation({
  args: {
    sessionToken: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = await getCurrentUser(ctx, args.sessionToken);
    const user = await ctx.db.get(userId);
    return user ? { username: user.username } : null;
  },
});

async function createSession(ctx: MutationCtx, userId: Id<"users">) {
  const sessionToken = randomToken(32);
  const tokenHash = await sha256(sessionToken);
  const now = Date.now();
  await ctx.db.insert("userSessions", {
    userId,
    tokenHash,
    createdAt: now,
    expiresAt: now + SESSION_DURATION_MS,
  });
  return sessionToken;
}

function normalizeUsername(username: string) {
  const normalized = username.trim().toLowerCase();
  if (!/^[a-z0-9_][a-z0-9_.-]{2,31}$/.test(normalized)) {
    throw new Error("Username must be 3-32 characters and use letters, numbers, dots, dashes, or underscores.");
  }
  return normalized;
}

function validatePassword(password: string) {
  if (password.length < 8) {
    throw new Error("Password must be at least 8 characters.");
  }
}

async function passwordDigest(salt: string, password: string) {
  return await sha256(`${salt}:${password}`);
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return bytesToHex(new Uint8Array(digest));
}

function randomToken(byteCount: number) {
  const bytes = crypto.getRandomValues(new Uint8Array(byteCount));
  return bytesToHex(bytes);
}

function bytesToHex(bytes: Uint8Array) {
  return [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}
