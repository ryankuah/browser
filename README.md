# Browser

A SwiftUI/WebKit browser experiment.

## Release

The release flow requires:

- A Developer ID Application certificate installed in Keychain Access.
- A stored notarytool profile, for example:

  ```sh
  xcrun notarytool store-credentials browser-notary \
    --apple-id you@example.com \
    --team-id TEAMID \
    --password app-specific-password
  ```

- The Sparkle `sign_update` tool at `build/sparkle-tools/bin/sign_update`, or `SPARKLE_SIGN_UPDATE` pointing to it.
- GitHub CLI authentication with permission to create releases.
- A clean git working tree.

Create a signed, notarized, tagged GitHub release:

```sh
NOTARYTOOL_PROFILE=browser-notary scripts/release.sh patch
```

The argument can be `patch`, `minor`, `major`, or an explicit version like `1.3.0`.

## Backlog

- Merge pending media permission toasts for the same origin. If a site requests camera and then requests microphone while the first permission toast is still pending, update the existing toast to "Camera and Microphone" instead of showing a second toast. Store both WebKit decision handlers on the same pending request and resolve them together when the user chooses Allow or Deny.
