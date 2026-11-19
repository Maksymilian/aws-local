# Project rules

## Languages
- **Scripting: Go, except simple scripts.**
  - Simple scripts (a few commands, no real logic: e.g. regenerate events,
    clear a table, print a table) are plain Bash `.sh` files.
  - Anything with real logic (test runners, process management, parsing,
    branching flows) is written in Go, in a Go module (e.g. `orders-test/tools`,
    run from that folder's parent with `go run ./tools <command>`, enabled
    by a `go.work` that uses `./tools`). Go code may call the `.sh` scripts.
  - No Python or Node scripts.
  - Files a third-party tool requires to be shell (e.g. LocalStack
    `init/ready.d/*.sh` hooks) stay shell regardless.
- **Lambda code: JavaScript only** (Node.js, ES modules, `.mjs`/`"type": "module"`).
  No TypeScript and no Python for new Lambda functions.
