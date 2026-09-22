# Front End Template

A minimal example web app showing how to drive the [job queue](../queue) from
a browser: enqueue a backup, poll its status/progress, and cancel it. This is
a starting point to copy/adapt, not a finished product - **no
authentication, no TLS, no input hardening beyond basic SSH shell-quoting.**
Don't expose it past localhost or a trusted network as-is.

It's the same integration shown in the main [README](../README.md#calling-the-queue-from-nodejs-remote-ssh)
("Calling the queue from Node.js"), just wired up to an actual HTTP server
and a plain-DOM front end instead of being left as a code snippet.

## How it fits together

```
Browser  --fetch()-->  server.js (Node, local)  --ssh-->  queue/*.sh (remote host)
```

- **`server.js`** - a dependency-free Node HTTP server. Each request shells
  out to `ssh` and invokes one queue script, same pattern as the README's
  `runQueueCommand`. It exposes a small REST-ish API (see below) and serves
  the static files in `public/`.
- **`public/index.html` + `public/app.js` + `public/style.css`** - a plain
  HTML/CSS/vanilla-JS page. No framework, no build step - open `app.js` to
  see exactly how each action maps to a `fetch()` call and how the response
  updates the DOM. Swap this for React/Vue/whatever; the `/api/*` contract
  in `server.js` is what actually matters.

## Setup

1. Copy `.env.example` to `.env` and fill in:
   - `QUEUE_SSH_HOST` / `QUEUE_SSH_PORT` / `QUEUE_SSH_USER` / `QUEUE_SSH_KEY_PATH`
     - SSH connection details for the host running the queue (same
       requirements as the main README's Node.js section: key-based auth,
       already in `known_hosts`).
   - `QUEUE_REMOTE_DIR` - absolute path to the `queue/` directory on that
     host, e.g. `/opt/Email-Backup/queue`.
2. `node server.js` (or `npm start`) - no `npm install` needed, this has zero
   dependencies.
3. Open `http://localhost:3000`.

## API

| Method | Path                              | Maps to                                | Notes |
|--------|-----------------------------------|-----------------------------------------|-------|
| GET    | `/api/jobs`                       | `queue-status.sh --all`                 | |
| GET    | `/api/jobs?mailbox=x@y.z`         | `queue-status.sh --mailbox <mailbox>`   | |
| GET    | `/api/jobs/:id`                   | `queue-status.sh <job_id>`              | includes live `progress` |
| POST   | `/api/jobs` `{mailbox, from?, to?}` | `queue-submit.sh backup <mailbox> ...`| enqueue |
| POST   | `/api/jobs/:id/cancel`            | `queue-cancel.sh --job <job_id>`        | see caveat below |
| POST   | `/api/mailboxes/:mailbox/cancel`  | `queue-cancel.sh <mailbox>`             | not wired up in the UI, but available |

**There's no separate "dequeue" operation.** Cancelling a job that hasn't
started yet is how you remove it from the queue - `queue-cancel.sh` handles
both cases. Cancelling is scoped to the *mailbox*, not one job: it also
drops every other queued chunk for that mailbox and deletes any `.pst`/`.zip`
output already produced for it. The UI's Cancel button confirms this before
sending the request.

## Extending this

- Add auth (even HTTP Basic in front of `server.js` via a reverse proxy) before
  putting this anywhere but localhost.
- The `upload` job type (manual retry of the upload step) isn't exposed in
  the UI - `runQueueScript("queue-submit.sh", ["upload", mailbox])` is all
  that's needed if you want it.
- Progress percent requires an upfront metadata pass on the backend before
  it appears - see the "Caveats" section of the main README.

<img width="947" height="666" alt="image" src="https://github.com/user-attachments/assets/f0052b5a-b7bb-47c8-8a22-10a02e1604b4" />
