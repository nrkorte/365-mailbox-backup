// Minimal HTTP front end for the SSH job queue in ../queue.
//
// This is a demo/integration example, not production code: no auth, no
// TLS, no input hardening beyond the shell-quoting needed to call SSH
// safely. Do not expose this past localhost/a trusted network as-is - see
// README.md in this folder.
"use strict";

const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");
const { execFile } = require("node:child_process");

loadDotEnvFile(path.join(__dirname, ".env"));

const SSH_HOST = process.env.QUEUE_SSH_HOST;
const SSH_PORT = process.env.QUEUE_SSH_PORT || "22";
const SSH_USER = process.env.QUEUE_SSH_USER;
const SSH_KEY_PATH = process.env.QUEUE_SSH_KEY_PATH;
const QUEUE_REMOTE_DIR = process.env.QUEUE_REMOTE_DIR;
const PORT = Number(process.env.PORT || 3000);

for (const [name, value] of Object.entries({
  QUEUE_SSH_HOST: SSH_HOST,
  QUEUE_SSH_USER: SSH_USER,
  QUEUE_SSH_KEY_PATH: SSH_KEY_PATH,
  QUEUE_REMOTE_DIR: QUEUE_REMOTE_DIR,
})) {
  if (!value) {
    console.error(`Missing ${name} - copy .env.example to .env and fill it in.`);
    process.exit(1);
  }
}

// Same pattern as the "Calling the queue from Node.js" section of the main
// README: shell out to the system ssh binary and run one queue script per
// call, quoting every argument for the remote shell.
function shQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function runQueueScript(scriptName, args) {
  const remotePath = `${QUEUE_REMOTE_DIR}/${scriptName}`;
  const remoteCommand = [remotePath, ...args].map(shQuote).join(" ");

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
        remoteCommand,
      ],
      { timeout: 15000, maxBuffer: 10 * 1024 * 1024 },
      (err, stdout, stderr) => {
        let parsed;
        try {
          parsed = JSON.parse((stdout || "").trim());
        } catch {
          return reject(new Error((stderr || "").trim() || err?.message || "no output"));
        }
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed) && "error" in parsed) {
          return reject(new Error(parsed.error));
        }
        resolve(parsed);
      }
    );
  });
}

// --- tiny router -----------------------------------------------------------

const STATIC_DIR = path.join(__dirname, "public");
const CONTENT_TYPES = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css" };

function sendJson(res, status, body) {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (chunk) => (data += chunk));
    req.on("end", () => {
      if (!data) return resolve({});
      try {
        resolve(JSON.parse(data));
      } catch {
        reject(new Error("invalid JSON body"));
      }
    });
    req.on("error", reject);
  });
}

function serveStatic(req, res, pathname) {
  const relPath = pathname === "/" ? "/index.html" : pathname;
  const filePath = path.join(STATIC_DIR, relPath);
  if (!filePath.startsWith(STATIC_DIR)) {
    res.writeHead(403).end("forbidden");
    return;
  }
  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404).end("not found");
      return;
    }
    const ext = path.extname(filePath);
    res.writeHead(200, { "Content-Type": CONTENT_TYPES[ext] || "application/octet-stream" });
    res.end(data);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const { pathname } = url;

  try {
    // GET /api/jobs                -> all jobs
    // GET /api/jobs?mailbox=x@y.z  -> jobs for one mailbox
    if (req.method === "GET" && pathname === "/api/jobs") {
      const mailbox = url.searchParams.get("mailbox");
      const jobs = mailbox
        ? await runQueueScript("queue-status.sh", ["--mailbox", mailbox])
        : await runQueueScript("queue-status.sh", ["--all"]);
      return sendJson(res, 200, jobs);
    }

    // GET /api/jobs/:id -> one job, merged with live progress
    const jobMatch = pathname.match(/^\/api\/jobs\/([^/]+)$/);
    if (req.method === "GET" && jobMatch) {
      const job = await runQueueScript("queue-status.sh", [jobMatch[1]]);
      return sendJson(res, 200, job);
    }

    // POST /api/jobs { mailbox, from?, to? } -> enqueue a backup job
    if (req.method === "POST" && pathname === "/api/jobs") {
      const { mailbox, from, to } = await readBody(req);
      if (!mailbox) return sendJson(res, 400, { error: "mailbox is required" });
      const args = ["backup", mailbox];
      if (from) args.push("--from", from);
      if (to) args.push("--to", to);
      const result = await runQueueScript("queue-submit.sh", args);
      return sendJson(res, 201, result);
    }

    // POST /api/jobs/:id/cancel -> cancel/dequeue by job id
    //
    // There's no separate "dequeue" script - cancelling a job that hasn't
    // started yet is how you remove it from the queue. Note this cascades:
    // it cancels every other queued chunk for the same mailbox too and
    // deletes any output already produced for it. See queue-cancel.sh.
    const cancelMatch = pathname.match(/^\/api\/jobs\/([^/]+)\/cancel$/);
    if (req.method === "POST" && cancelMatch) {
      const result = await runQueueScript("queue-cancel.sh", ["--job", cancelMatch[1]]);
      return sendJson(res, 200, result);
    }

    // POST /api/mailboxes/:mailbox/cancel -> cancel everything for a mailbox
    const mailboxCancelMatch = pathname.match(/^\/api\/mailboxes\/([^/]+)\/cancel$/);
    if (req.method === "POST" && mailboxCancelMatch) {
      const mailbox = decodeURIComponent(mailboxCancelMatch[1]);
      const result = await runQueueScript("queue-cancel.sh", [mailbox]);
      return sendJson(res, 200, result);
    }

    if (req.method === "GET") {
      return serveStatic(req, res, pathname);
    }

    sendJson(res, 404, { error: "no such route" });
  } catch (err) {
    sendJson(res, 502, { error: err.message });
  }
});

server.listen(PORT, () => {
  console.log(`Front end template listening on http://localhost:${PORT}`);
});

// Same minimal .env loader as Program.cs / the shell scripts - no
// dependency on dotenv just for a template.
function loadDotEnvFile(filePath) {
  if (!fs.existsSync(filePath)) return;
  for (const line of fs.readFileSync(filePath, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    const value = trimmed.slice(eq + 1).trim();
    if (!(key in process.env)) process.env[key] = value;
  }
}
