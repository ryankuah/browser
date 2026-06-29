# Convex and Google Setup

This repo now contains the SwiftUI app plus a Convex backend.

## Convex

1. Run `npm install`.
2. Run `npx convex dev` and create/link a Convex project.
3. Set deployment env vars:

```sh
npx convex env set AUTH0_DOMAIN https://YOUR_AUTH0_DOMAIN
npx convex env set AUTH0_CLIENT_ID YOUR_AUTH0_CLIENT_ID
npx convex env set GOOGLE_CLIENT_ID YOUR_GOOGLE_CLIENT_ID
npx convex env set GOOGLE_CLIENT_SECRET YOUR_GOOGLE_CLIENT_SECRET
npx convex env set GOOGLE_OAUTH_REDIRECT_URI https://YOUR_CONVEX_SITE/api/google/oauth/callback
npx convex env set GOOGLE_GMAIL_PUBSUB_TOPIC projects/YOUR_PROJECT/topics/YOUR_TOPIC
npx convex env set GOOGLE_TOKEN_ENCRYPTION_SECRET "a-long-random-secret"
```

For local app testing, set `BROWSER_CONVEX_URL` before launching from Xcode, or put your Convex client URL in `BrowserConvexURL` in `Browser/Info.plist`.

## App Accounts

Browser now uses a handrolled Convex auth system. Users create an account with only:

- username
- password

The backend stores salted password hashes and issues opaque session tokens. The macOS app stores only the session token in Keychain.

## Google

Google is import-only. The backend requests only:

- `https://www.googleapis.com/auth/gmail.readonly`
- `https://www.googleapis.com/auth/calendar.readonly`

Do not add Gmail or Calendar write scopes. `npm run test:google-readonly` guards the Convex source against common Google write scopes/endpoints.
