// Plain DOM integration example: no framework, just fetch() + manual
// rendering. Swap this file out for React/Vue/whatever - the /api/*
// contract in server.js is what actually matters.
"use strict";

const POLL_INTERVAL_MS = 3000;

const submitForm = document.getElementById("submit-form");
const submitResult = document.getElementById("submit-result");
const jobsBody = document.getElementById("jobs-body");
const mailboxFilter = document.getElementById("mailbox-filter");
const refreshBtn = document.getElementById("refresh-btn");
const pollIndicator = document.getElementById("poll-indicator");

const STATUS_CLASS = {
  queued: "status-queued",
  running: "status-running",
  done: "status-done",
  failed: "status-failed",
  cancelled: "status-cancelled",
};

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[c]));
}

async function api(path, options) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.error || `request failed (${res.status})`);
  return body;
}

// --- enqueue -----------------------------------------------------------

submitForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const formData = new FormData(submitForm);
  const mailbox = formData.get("mailbox")?.trim();
  const from = formData.get("from") || undefined;
  const to = formData.get("to") || undefined;

  submitResult.textContent = "Submitting…";
  submitResult.className = "result";

  try {
    const job = await api("/api/jobs", {
      method: "POST",
      body: JSON.stringify({ mailbox, from, to }),
    });
    submitResult.textContent = `Queued job ${job.job_id} for ${job.mailbox}`;
    submitResult.className = "result result-ok";
    submitForm.reset();
    loadJobs();
  } catch (err) {
    submitResult.textContent = `Error: ${err.message}`;
    submitResult.className = "result result-error";
  }
});

// --- cancel / dequeue ----------------------------------------------------
//
// There's no separate "dequeue" endpoint - cancelling a job that hasn't
// started yet removes it from the queue. Cancelling also cascades to every
// other queued chunk for the same mailbox and deletes any output already
// produced for it (see queue-cancel.sh / server.js).

async function cancelJob(jobId) {
  if (!confirm(`Cancel job ${jobId}? This cancels/deletes ALL output for its mailbox.`)) return;
  try {
    await api(`/api/jobs/${encodeURIComponent(jobId)}/cancel`, { method: "POST" });
    loadJobs();
  } catch (err) {
    alert(`Cancel failed: ${err.message}`);
  }
}

// --- poll status / render -------------------------------------------------

function renderJobs(jobs) {
  if (!jobs.length) {
    jobsBody.innerHTML = `<tr><td colspan="8" class="empty">No jobs yet.</td></tr>`;
    return;
  }

  jobsBody.innerHTML = jobs.map((job) => {
    const statusClass = STATUS_CLASS[job.status] || "";
    const percent = job.progress?.percent;
    const progressCell = percent == null
      ? "—"
      : `<div class="progress-bar"><div class="progress-fill" style="width:${percent}%"></div></div><span>${percent}%</span>`;
    const canCancel = job.status === "queued" || job.status === "running";

    return `
      <tr>
        <td><code>${escapeHtml(job.id)}</code></td>
        <td>${escapeHtml(job.mailbox)}</td>
        <td>${escapeHtml(job.type)}</td>
        <td><span class="status-badge ${statusClass}">${escapeHtml(job.status)}</span></td>
        <td>${escapeHtml(job.phase || "—")}</td>
        <td>${progressCell}</td>
        <td>${escapeHtml(job.submitted_at)}</td>
        <td>
          ${canCancel ? `<button type="button" data-cancel="${escapeHtml(job.id)}">Cancel</button>` : "—"}
        </td>
      </tr>`;
  }).join("");

  jobsBody.querySelectorAll("[data-cancel]").forEach((btn) => {
    btn.addEventListener("click", () => cancelJob(btn.dataset.cancel));
  });
}

async function loadJobs() {
  pollIndicator.textContent = "Refreshing…";
  try {
    const mailbox = mailboxFilter.value.trim();
    const jobs = mailbox
      ? await api(`/api/jobs?mailbox=${encodeURIComponent(mailbox)}`)
      : await api("/api/jobs");
    renderJobs(jobs);
    pollIndicator.textContent = `Updated ${new Date().toLocaleTimeString()}`;
  } catch (err) {
    pollIndicator.textContent = `Error: ${err.message}`;
  }
}

refreshBtn.addEventListener("click", loadJobs);
mailboxFilter.addEventListener("change", loadJobs);

loadJobs();
setInterval(loadJobs, POLL_INTERVAL_MS);
