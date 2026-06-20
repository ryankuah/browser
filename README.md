# Browser

A SwiftUI/WebKit browser experiment.

## Backlog

- Merge pending media permission toasts for the same origin. If a site requests camera and then requests microphone while the first permission toast is still pending, update the existing toast to "Camera and Microphone" instead of showing a second toast. Store both WebKit decision handlers on the same pending request and resolve them together when the user chooses Allow or Deny.
