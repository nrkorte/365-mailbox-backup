# M365 Mailbox -> PST Backup

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![.NET](https://img.shields.io/badge/.NET-8.0-512BD4)](M365Backup.csproj)

A free, open-source command-line tool that backs up any **Microsoft 365 /
Office 365 / Exchange Online mailbox to a standard `.pst` file** via the
Microsoft Graph API, using app-only OAuth2 (client credentials) — no
interactive sign-in, no Basic Auth, no per-mailbox delegated consent.

Most tools that do this — exporting an M365 or Exchange Online mailbox to PST
for e-discovery, offboarding, compliance archiving, or disaster recovery — are
closed-source commercial products billed per mailbox or per seat (CodeTwo
Backup, Stellar/SysTools Office 365 Backup, Mail Backup X, Veeam, etc.). This
project does the same job as a self-hosted, scriptable, source-available
alternative. The only cost is an [Aspose.Email for
.NET](https://products.aspose.com/email/net/) license (or its free evaluation
mode) — everything else here is free to use, fork, and modify under the MIT
license.

## Features

- **Full mailbox export to PST** — every folder, recursively, via Microsoft
  Graph (`Aspose.Email.Clients.Graph`).
- **App-only OAuth2 auth** (MSAL client-credentials flow) — no signed-in user,
  no mailbox owner interaction required; works against any mailbox in the
  tenant once admin-consented.
- **Date-range chunking** (`--from`/`--to`) to break very large mailboxes into
  manageable pieces, e.g. year over year.
- **Resumable, crash-safe backups** — an interrupted run picks up close to
  where it left off instead of starting over.
- **Automatic size-based PST chunking** so output files stay under a
  configurable limit (default 15 GB).
- **Job queue** for remote/automated triggering — submit a backup over SSH,
  disconnect, and poll for status (including live percent-complete) later.
  Ships with systemd unit files for the worker, plus optional daily
  maintenance / weekly reboot timers.
- **Dropbox upload** via `rclone`, with zip + checksum verification before
  the local copy is deleted.
- Cross-platform wrapper scripts for both **PowerShell** and **bash**.

## Prerequisites

Software to have installed before following any of the steps below:

- **[.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0)** - to
  build/run the backup tool itself (`dotnet run`, or `dotnet` invoked by the
  job queue).
- **`jq`** - used throughout the job queue scripts (`queue/*.sh`) to read and
  write job state. `apt install jq` / `brew install jq` / `choco install jq`.
- **`zip`** - used by `upload-mailbox-backup.sh` to combine multiple PST
  chunks into one file before upload. `apt install zip`.
- **[`rclone`](https://rclone.org)** - only needed for the Dropbox upload
  step (manual or via the job queue) - see "Uploading a finished backup to
  Dropbox" below.
- A Linux host with **systemd**, only if you're deploying the job queue as a
  long-running service (see "Job queue" below) rather than running backups
  by hand with `dotnet run` / the wrapper scripts.

## Requirements

1. **An Entra ID (Azure AD) app registration**, created once:
   1. In the [Entra admin center](https://entra.microsoft.com) → **App
      registrations** → **New registration**. Any name works; no redirect
      URI is needed - this app never signs a user in interactively.
   2. **Certificates & secrets** → **New client secret**. Copy its *value*
      immediately (not the secret ID) - you can't retrieve it again later.
      This is `M365_CLIENT_SECRET` below.
   3. **API permissions** → **Add a permission** → **Microsoft Graph** →
      **Application permissions** → add `Mail.Read` (or `Mail.ReadWrite` if
      you'll ever need to write back) → **Grant admin consent for
      &lt;tenant&gt;**. Granting consent requires a Global Administrator or
      Privileged Role Administrator.
   4. On the app's **Overview** page, copy the **Application (client) ID**
      (`M365_CLIENT_ID`) and **Directory (tenant) ID** (`M365_TENANT_ID`).

   This permission gives the app access to *every* mailbox in the tenant, so
   it can target any mailbox by address without that mailbox's owner doing
   anything - see `client.ResourceId` in `Program.cs`.

2. A `.env` file in the project folder (see `.env.example`):

   ```
   M365_TENANT_ID=<tenant-id-guid>
   M365_CLIENT_ID=<app-registration-client-id>
   M365_CLIENT_SECRET=<client-secret-value>
   # Optional overrides - see .env.example and Program.cs for defaults/details:
   # M365_PST_PATH, M365_CHUNK_SIZE_GB, M365_GRAPH_MAX_REQUESTS_PER_SECOND
   ```

   The job queue has a couple of its own, separate environment variables -
   see "Queue-specific environment variables" under "Job queue" below.

3. **An Aspose.Email license** - this project uses the
   [Aspose.Email for .NET](https://products.aspose.com/email/net/) library,
   which runs in a limited evaluation mode without one. Get a
   [temporary license](https://purchase.aspose.com/temp-license/97140) for
   testing/evaluation, or a [full license](https://purchase.aspose.com/pricing/email/net/)
   for production use. Drop the license file in the project root next to
   `Program.cs`, named `Aspose.Emailfor.NET.lic` (see `licensePath` in
   `Program.cs`).

   > **Staying on the free tier long-term:** the temporary license is good
   > for 30 days; requesting a new one every 30 days keeps you on it
   > indefinitely if that's preferable to buying one. A reasonable path: get
   > a temporary license first, confirm the whole setup works end to end,
   > *then* decide whether a perpetual license is worth it for your use.
   > Check the license tier carefully against how you intend to run this -
   > tiers differ on things like distributing the resulting software to
   > other people, not just on price.

## Running a backup directly

```
dotnet run -- <mailbox> [--from yyyy-MM-dd] [--to yyyy-MM-dd]
```

`--from`/`--to` are both optional and independent - omit both to back up the
entire mailbox, or set either/both to carve out a date range (`--from`
inclusive, `--to` exclusive). Use this to chunk a very large mailbox into
manageable pieces instead of one long run, e.g. year over year:

```
dotnet run -- someone@example.com --from 2023-01-01 --to 2024-01-01
dotnet run -- someone@example.com --from 2024-01-01 --to 2025-01-01
dotnet run -- someone@example.com --from 2025-01-01   # everything since, no upper bound
```

Or use the wrapper script, which prompts for a mailbox if omitted and derives
a PST path automatically:

```powershell
.\backup-mailbox.ps1 -Mailbox someone@example.com -From 2023-01-01 -To 2024-01-01
```

```bash
./backup-mailbox.sh someone@example.com --from 2023-01-01 --to 2024-01-01
```

See `Program.cs` for how output filenames/chunking are derived.

## Uploading a finished backup to Dropbox

`upload-mailbox-backup.sh` is a **separate script, run by hand, after all the
chunked backup runs for a mailbox are done** - running it mid-chunking would
upload (and delete) an incomplete set. (Going through the job queue instead
invokes this automatically - see below.)

```bash
./upload-mailbox-backup.sh someone@example.com
```

It zips multiple chunks together (or uploads a single file as-is), uploads
via `rclone`, verifies with a checksum comparison, and only deletes the local
file(s) once that verification passes.

One-time setup: install **[rclone](https://rclone.org)** and configure a
remote pointing at your Dropbox account (`rclone config`), then copy
`rclone-upload.env.example` to `rclone-upload.env` and fill in
`RCLONE_REMOTE`/`DROPBOX_FOLDER`.

## Job queue (for remote/automated triggering)

A backup can take hours, so triggering one directly requires holding a
connection open the whole time. The job queue under `queue/` lets a remote
caller **submit a job and disconnect**, then **poll for status later**
(including live percent-complete), and **cancel** a job.

A persistent worker (`queue/queue-worker.sh`, meant to run as a systemd
service under a dedicated account) processes jobs **one at a time** - never
in parallel, since every mailbox shares the same Entra app registration/
tenant and Exchange Online throttles at that level.

```
queue/queue-submit.sh backup <mailbox> [--from yyyy-MM-dd] [--to yyyy-MM-dd]
queue/queue-submit.sh upload <mailbox>   (manual recovery only)
queue/queue-status.sh <job_id>
queue/queue-status.sh --mailbox <mailbox>
queue/queue-status.sh --all
queue/queue-cancel.sh <mailbox>
queue/queue-cancel.sh --job <job_id>
```

All commands print JSON to stdout. A `backup` job automatically chains into
its own zip+upload once it (and any sibling date-range chunks for the same
mailbox) finishes - you only ever need to submit `backup` and poll it through
to `done`/`failed`. `upload` is only for manually retrying the upload step on
its own. See each script's header comment for the full field/behavior list.

### Queue-specific environment variables

These are read directly from the process environment by the bash scripts in
`queue/` - unlike `M365_TENANT_ID`/etc. above, they're **not** read from a
`.env` file, so set them where the worker actually runs (e.g. `Environment=`
lines in the systemd unit below):

- `M365_BACKUP_DIR` - where PST/zip output and resume state live. Defaults
  to `/data/backups` - make sure that path exists, is writable by whichever
  account runs the worker, and is sized for your largest mailbox (a full
  export can be tens of GB).
- `M365_MAX_AUTO_RETRIES` - how many consecutive times a job auto-resumes
  after a crash/kill/unclean restart before giving up and leaving it
  `failed` for a human. Defaults to `5`. See "Caveats" below.

### Deploying the worker as a service

`queue/queue-worker.sh` is a long-running process, not a one-off script - it
needs to be started once and kept running (through reboots, crashes, etc.)
for the queue to actually process anything. On Linux, that means a systemd
service:

1. Create a dedicated, unprivileged account to run it as (never run the
   worker as root):
   ```bash
   sudo useradd --system --create-home --shell /usr/sbin/nologin m365backup
   ```
2. Clone/place this repo somewhere that account can read and write, e.g.
   `/opt/m365backup`, with `.env` and (if using one) the Aspose license file
   in place, owned by that account.
3. Make sure `M365_BACKUP_DIR` (default `/data/backups`) exists and is
   writable by that account.
4. Copy [`systemd/m365backup-queue.service`](systemd/m365backup-queue.service)
   to `/etc/systemd/system/`, edit its `User`/`Group`/`WorkingDirectory`/
   `ExecStart` to match where you put the repo and which account owns it,
   then:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now m365backup-queue.service
   sudo systemctl status m365backup-queue.service   # confirm it's running
   journalctl -u m365backup-queue.service -f        # follow its output
   ```

That's the whole requirement for the job queue to work - everything in
"Calling the queue from Node.js" below assumes this service is running.

### Scheduled maintenance and reboots (optional)

Two more scripts under `queue/` exist for keeping a long-running deployment
patched, and are **not required** for the queue to function - only install
them if you want this host to patch and restart itself unattended:

- **`queue/queue-maintenance.sh`** (daily) - waits for the queue to go idle,
  installs pending OS package upgrades, then restarts
  `m365backup-queue.service` so any upgraded library gets picked up at a
  controlled time instead of mid-backup. Never reboots the host.
- **`queue/queue-weekly-reboot.sh`** (weekly) - the same upgrade step, but
  **also reboots the entire host** if it's idle at the time - for upgrades
  (e.g. a new kernel) that only take effect after a reboot. Skips itself
  entirely if the queue isn't idle when it checks.

If you want them, install both the `.service` and matching `.timer` for
each from [`systemd/`](systemd/) (unit files include the exact `cp`/
`systemctl enable` commands):

```bash
sudo cp systemd/m365backup-maintenance.{service,timer} systemd/m365backup-weekly-reboot.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now m365backup-maintenance.timer
sudo systemctl enable --now m365backup-weekly-reboot.timer   # optional - see WARNING in the .service file
```

Both need to run as root (`apt-get`, `systemctl restart`/`reboot`) - that's
the default for a systemd service with no `User=` set, which is what the
provided unit files do.

## Calling the queue from Node.js (remote SSH)

Prerequisite: the calling host needs SSH key-based access to whichever
account can read/write `queue/` on the host running
`m365backup-queue.service` above (the dedicated `m365backup` account from
"Deploying the worker as a service" works, or any account with access to
that directory) - generate a key pair for this purpose and add it to that
account's `~/.ssh/authorized_keys` if you haven't already.

A remote caller never talks to the queue's filesystem directly - it opens an
SSH session and invokes each queue script as a one-off command. The examples
below use `child_process.execFile` to shell out to the system `ssh` binary
rather than an SSH client library, so whatever `~/.ssh/config`/known_hosts/
agent setup already exists on the calling host applies with no extra plumbing.
Connection details (host, port, user, key path) and script locations are read
from configuration rather than hardcoded, so the same helper works against any
target.

```js
const { execFile } = require("child_process");

const SSH_HOST = process.env.QUEUE_SSH_HOST;
const SSH_PORT = process.env.QUEUE_SSH_PORT || "22";
const SSH_USER = process.env.QUEUE_SSH_USER;
const SSH_KEY_PATH = process.env.QUEUE_SSH_KEY_PATH;

// Single-quotes a value for safe inclusion in the remote shell command string -
// do this even for input already validated locally, as a second independent
// layer against command injection on the remote host.
function shQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

// Runs one queue script over SSH and parses its single JSON line of output.
// Rejects on a non-JSON response, and also when the script itself reports
// {"error": "..."} - callers only ever see either resolved JSON or a rejected
// Promise, never a raw {error} payload to inspect by hand.
function runQueueCommand(argv) {
  const remoteCommand = argv.map(shQuote).join(" ");

  return new Promise((resolve, reject) => {
    execFile(
      "ssh",
      [
        "-i", SSH_KEY_PATH,
        "-p", SSH_PORT,
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ConnectTimeout=10",
        `${SSH_USER}@${SSH_HOST}`,
        remoteCommand
      ],
      { timeout: 15000, maxBuffer: 10 * 1024 * 1024 },
      (err, stdout, stderr) => {
        let parsed;
        try {
          parsed = JSON.parse((stdout || "").trim());
        } catch {
          return reject(new Error((stderr || "").trim() || err?.message || "no output"));
        }
        if (parsed && typeof parsed === "object" && "error" in parsed) {
          return reject(new Error(parsed.error));
        }
        resolve(parsed);
      }
    );
  });
}
```

### Init (submit) a job

```js
async function submitJob(target, options = {}) {
  const argv = ["queue-submit.sh", target];
  for (const [flag, value] of Object.entries(options)) {
    argv.push(`--${flag}`, value);
  }
  return runQueueCommand(argv); // -> { job_id, status: "queued", ... }
}
```

### Poll status

```js
async function getJobStatus(jobId) {
  return runQueueCommand(["queue-status.sh", jobId]);
}

async function getJobsForTarget(target) {
  return runQueueCommand(["queue-status.sh", "--target", target]); // -> array, [] if none
}

async function getAllJobs() {
  return runQueueCommand(["queue-status.sh", "--all"]);
}

// Simple poll loop - in a real caller, prefer a scheduled interval over a
// blocking sleep loop like this so the process can still handle other work.
async function pollUntilDone(jobId, intervalMs = 5000) {
  for (;;) {
    const job = await getJobStatus(jobId);
    if (["done", "failed", "cancelled"].includes(job.status)) return job;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}
```

### Cancel a job

```js
async function cancelJob(jobId) {
  return runQueueCommand(["queue-cancel.sh", "--job", jobId]);
}
```

### Working example

The snippets above are wired up into an actual running app in
[`Front End Template/`](Front%20End%20Template/) - a small Node HTTP server
plus a plain HTML/JS page showing enqueue, poll-status-with-progress, and
cancel/dequeue against a real DOM. Not production-ready (no auth), but a
concrete starting point instead of just code fragments.

## Caveats

- **Cancelling a mailbox's backup deletes its output.** `queue-cancel.sh` is
  scoped to the mailbox, not one job - it kills/drops every queued chunk for
  that mailbox and deletes every `.pst`/`.zip` already produced for it. This
  is the *only* thing that wipes output.
- **A crash, kill, or unclean worker restart is NOT treated as a cancel.**
  The queue keeps a durable, crash-safe record of what's already copied and
  automatically resumes the same mailbox/range close to where it left off,
  up to `M365_MAX_AUTO_RETRIES` (default 5) consecutive attempts before
  giving up and leaving the job `failed` for a human. See `ResumeState` in
  `Program.cs` and `handle_interrupted_backup` in `queue/queue-lib.sh`.
- **Percent-complete has an upfront cost.** Getting an accurate total item
  count for progress reporting requires a metadata-only pass before the real
  copy starts; for a mailbox with very large folders this can take a couple
  of minutes before `"progress"` first appears in `queue-status.sh` output.
- **PST chunking is by on-disk file size** (`M365_CHUNK_SIZE_GB`, default 15
  GB), not item count - see `PstChunkWriter` in `Program.cs`.
- Only one job runs at a time across the whole queue, by design (see Job
  queue section above) - a large batch of mailboxes will run sequentially,
  not concurrently.
