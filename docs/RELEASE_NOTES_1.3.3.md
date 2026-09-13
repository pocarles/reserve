# Reserve 1.3.3

This release fixes a crash when signing in to Claude and removes the windows
around a sign-in that went well.

- Signing in to Claude no longer closes Reserve. The installed app looked for
  its bundled sign-in helper in the temporary folder that built it, which no
  longer existed, and stopped instead of opening the browser. It now reads the
  helper from inside Reserve.app.
- Packaging refuses a build whose sign-in helper cannot be found or run from
  inside the app, so this cannot come back unnoticed.
- Connecting no longer shows a window before the browser opens or a
  "connected" confirmation afterwards. The provider card shows the sign-in in
  progress and fills in when usage arrives. A window appears only when Reserve
  needs a decision from you, such as installing a helper or allowing usage
  access, or has a problem to explain. Choose **Connect** again during a
  sign-in to reopen the browser page.

Provider connections, saved sign-ins, and settings are untouched.
