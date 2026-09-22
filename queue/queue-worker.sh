#!/usr/bin/env bash
# Long-running worker: claims jobs one at a time from pending/, runs them,
# records status. Meant to run as a persistent systemd service under a
# dedicated non-root service account - not invoked directly by hand normally.
set -euo pipefail
set -m  # job control: each backgrounded job gets its own process group, so
        # queue-cancel.sh's `kill -TERM -- -$pid` reaches zip/rclone children
        # of an upload job too, not just a single PID.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_DIR/queue/queue-lib.sh"

DLL="$PROJECT_DIR/bin/Debug/net8.0/M365Backup.dll"
UPLOAD_SCRIPT="$PROJECT_DIR/upload-mailbox-backup.sh"

cd "$PROJECT_DIR"  # Program.cs resolves .env / the Aspose license via
                    # Directory.GetCurrentDirectory() - this must be set
                    # before the dotnet DLL is ever invoked below.

exec 8>"$WORKER_LOCK"
if ! flock -n 8; then
    echo "Another queue-worker.sh instance already holds the lock - exiting." >&2
    exit 1
fi

log() { echo "[$(now_iso)] $*"; }

# Defensive cleanup: this flag should never outlive the worker generation
# that set it (queue-maintenance.sh sets it, waits, then clears it itself).
# If it's still here at startup, whatever set it never got to clear it -
# left alone, that would pause job claims forever.
if [ -e "$MAINTENANCE_PAUSE_FLAG" ]; then
    log "Clearing a stale maintenance-pause flag left over from before this worker started."
    rm -f "$MAINTENANCE_PAUSE_FLAG"
fi

# If the backup directory lives on a separate mount that failed to come up,
# every job would otherwise fail with a confusing low-level I/O error deep
# in Program.cs. Surface it clearly, once, right here instead.
if [ ! -w "$BACKUP_DIR" ]; then
    log "WARNING: $BACKUP_DIR is not writable - is /data mounted? Backups will fail until this is fixed."
fi

# --- Startup reconciliation -------------------------------------------------
# If the worker (or the whole box) died mid-job, a job record can be left
# behind claiming status=running with a stale or coincidentally-reused pid.
# An "upload" job (no mid-job checkpoint of its own) gets the full
# cascade-cancel wipe. A "backup" job instead goes through
# handle_interrupted_backup: its PST/resume-state is left alone (Program.cs's
# ResumeState already made it safely resumable) and it's auto-requeued to
# pick back up on its own.
log "Starting reconciliation pass..."
shopt -s nullglob
for jf in "$JOBS_DIR"/*.json; do
    status=$(jq -r '.status' "$jf")
    [ "$status" = "running" ] || continue

    id=$(jq -r '.id' "$jf")
    mailbox=$(jq -r '.mailbox' "$jf")
    type=$(jq -r '.type' "$jf")

    if [ "$type" != "backup" ]; then
        log "Reconciling stale running job $id ($mailbox) - cascading cancel."
        cascade_cancel_mailbox "$mailbox" "worker restarted while running; treated as cancelled" > /dev/null
        continue
    fi

    phase=$(jq -r '.phase // empty' "$jf")
    if [ "$phase" = "uploading" ]; then
        # The backup half already finished successfully before the restart -
        # Program.cs's ResumeState already self-deleted (see Complete()), so
        # requeuing a new "backup" job here would delete the already-complete
        # PST and redo the ENTIRE mailbox from scratch. Only the (cheaper)
        # upload half needs retrying - what "upload" jobs are for.
        log "Reconciling stale running job $id ($mailbox) - backup was already complete, only upload was interrupted; requeuing upload only."
        handle_backup_already_complete "$id" "$mailbox" "$jf"
        continue
    fi

    # A crash between run_job's backup-success fold-in and its .phase =
    # "uploading" transition leaves .phase stuck at "backup" even though the
    # export itself fully finished. The manifest file (still here, since the
    # backstop sweep below hasn't run yet) is the only remaining evidence of
    # that - check it before assuming "backup" phase means a genuinely
    # interrupted run.
    mf="$(manifest_file "$id")"
    if [ -f "$mf" ] && [ "$(jq -r '.completed // false' "$mf")" = "true" ]; then
        m_expected=$(jq -r '.total_expected // "null"' "$mf")
        m_copied=$(jq -r '.total_copied // "null"' "$mf")
        m_skipped=$(jq -r '.total_skipped // 0' "$mf")
        log "Reconciling stale running job $id ($mailbox) - manifest shows the backup itself finished before the crash; requeuing upload only instead of redoing the whole export."
        handle_backup_already_complete "$id" "$mailbox" "$jf" "$m_expected" "$m_copied" "$m_skipped"
        continue
    fi

    from=$(jq -r '.from // empty' "$jf")
    to=$(jq -r '.to // empty' "$jf")
    pf="$(progress_file "$id")"
    copied="?"; total="?"
    if [ -f "$pf" ]; then
        copied=$(jq -r '.copied_items // "?"' "$pf")
        total=$(jq -r '.total_items // "?"' "$pf")
    fi
    rm -f "$pf"

    log "Reconciling stale running job $id ($mailbox) - $copied/$total item(s) already copied, will resume."
    handle_interrupted_backup "$id" "$mailbox" "$from" "$to" \
        "worker restarted while running - $copied/$total item(s) already copied"
done

# Backstop for manifests left behind by a box/worker crash that happened
# before run_job's own unconditional cleanup got to run. Any file still here
# at a fresh worker start belongs to a job that's either just been
# reconciled to cancelled above or was already terminal - its data is
# already superseded by that job's log file, so it's always safe to drop.
mkdir -p "$MANIFEST_DIR"
for mf in "$MANIFEST_DIR"/*.json; do
    rm -f "$mf"
done
log "Reconciliation done."

# --- Job execution -----------------------------------------------------------
# A "backup" job runs its own zip+upload immediately afterward, in the same
# job/log/pid. "upload" is still a submittable job type, but only for manual
# recovery (retrying just the upload half after a previous verify failure) -
# see queue-submit.sh's header comment.
#
# A mailbox can still have several backup jobs queued (year-by-year
# --from/--to chunks submitted one at a time) - the upload only ever runs
# from whichever chunk turns out to be the LAST to finish. Since the worker
# only ever runs one job at a time, there's no window where two sibling
# chunks could both think they're "last."
mailbox_has_pending_backup_sibling() {
    local mailbox="$1" exclude_id="$2"
    local sib_jf
    for sib_jf in "$JOBS_DIR"/*.json; do
        [ "$(basename "$sib_jf" .json)" = "$exclude_id" ] && continue
        [ "$(jq -r '.mailbox' "$sib_jf")" = "$mailbox" ] || continue
        [ "$(jq -r '.type' "$sib_jf")" = "backup" ] || continue
        case "$(jq -r '.status' "$sib_jf")" in
            queued|running) return 0 ;;
        esac
    done
    return 1
}

run_job() {
    local id="$1"
    local jf
    jf="$(job_file "$id")"
    local type mailbox from to lf pf mf pid backup_exit upload_exit cancel_requested
    local manifest_json copied total

    type=$(jq -r '.type' "$jf")
    mailbox=$(jq -r '.mailbox' "$jf")
    from=$(jq -r '.from // empty' "$jf")
    to=$(jq -r '.to // empty' "$jf")
    lf="$(log_file "$id")"
    pf="$(progress_file "$id")"
    mf=""

    atomic_jq_update "$jf" '.status = "running" | .started_at = $now' --arg now "$(now_iso)"
    log "Starting job $id: $type $mailbox ${from:+--from $from} ${to:+--to $to}"

    if [ "$type" != "backup" ]; then
        # Manual-recovery "upload" job - unchanged single-phase behavior.
        "$UPLOAD_SCRIPT" "$mailbox" > "$lf" 2>&1 &
        pid=$!
        atomic_jq_update "$jf" '.pid = $pid' --argjson pid "$pid"

        set +e
        wait "$pid"
        backup_exit=$?  # reused as the single exit code for this branch
        set -e

        cancel_requested=$(jq -r '.cancel_requested' "$jf")
        if [ "$cancel_requested" = "true" ]; then
            log "Job $id ($mailbox) was cancelled."
        elif [ "$backup_exit" -eq 0 ]; then
            atomic_jq_update "$jf" '.status = "done" | .exit_code = $ec | .finished_at = $now' \
                --argjson ec "$backup_exit" --arg now "$(now_iso)"
            log "Job $id ($mailbox) done."
        else
            atomic_jq_update "$jf" '.status = "failed" | .exit_code = $ec | .finished_at = $now
                | .note = "upload failed - local backup file(s) kept for retry, see log"
                | .will_retry = false | .next_job_id = null' \
                --argjson ec "$backup_exit" --arg now "$(now_iso)"
            log "Job $id ($mailbox) FAILED (exit $backup_exit) - see $lf"
        fi

        rm -f "$(running_marker "$id")"
        return
    fi

    # --- backup phase --------------------------------------------------------
    mf="$(manifest_file "$id")"
    atomic_jq_update "$jf" '.phase = "backup"'
    local dotnet_args=("$mailbox" --progress-file "$pf" --manifest-file "$mf")
    [ -n "$from" ] && dotnet_args+=(--from "$from")
    [ -n "$to" ] && dotnet_args+=(--to "$to")
    dotnet "$DLL" "${dotnet_args[@]}" > "$lf" 2>&1 &
    pid=$!
    atomic_jq_update "$jf" '.pid = $pid' --argjson pid "$pid"

    set +e
    wait "$pid"
    backup_exit=$?
    set -e

    # copied/total come from the progress file, not the manifest: manifest's
    # total_copied only gets set on a clean finish, so it's null on a crash.
    #
    # Pull just the three total_* scalars out with jq -r on the file instead
    # of reading the whole manifest into a shell variable - a mailbox with a
    # lot of skipped items can make that file huge (one entry per skip), and
    # passing the whole blob as a jq --argjson argument can blow past the
    # OS's argv size limit and take the whole worker down.
    m_expected="null"; m_copied="null"; m_skipped="0"
    if [ -f "$mf" ]; then
        m_expected=$(jq -r '.total_expected // "null"' "$mf")
        m_copied=$(jq -r '.total_copied // "null"' "$mf")
        m_skipped=$(jq -r '.total_skipped // 0' "$mf")
    fi
    copied="?"; total="?"
    if [ -f "$pf" ]; then
        copied=$(jq -r '.copied_items // "?"' "$pf")
        total=$(jq -r '.total_items // "?"' "$pf")
    fi
    rm -f "$pf"  # progress is only meaningful while the backup itself runs

    cancel_requested=$(jq -r '.cancel_requested' "$jf")
    if [ "$cancel_requested" = "true" ]; then
        # cascade_cancel_mailbox (triggered by queue-cancel.sh) already marked
        # this job's record cancelled and cleaned up its files - nothing more
        # to do here, just log it.
        log "Job $id ($mailbox) was cancelled during backup."
        rm -f "$mf"
        rm -f "$(running_marker "$id")"
        return
    fi

    if [ "$backup_exit" -ne 0 ]; then
        atomic_jq_update "$jf" '
            .items_expected = $expected
            | .items_copied  = $copied
            | .items_skipped = $skipped
            | .phase = "backup" | .exit_code = $ec' \
            --argjson expected "$m_expected" --argjson copied "$m_copied" --argjson skipped "$m_skipped" --argjson ec "$backup_exit"
        log "Job $id ($mailbox) FAILED during backup (exit $backup_exit) - $copied/$total item(s) already copied - see $lf"

        # The PST(s) this job produced are deliberately NOT deleted here -
        # Program.cs's ResumeState keeps a durable record of what's already
        # copied, so keeping them around is what lets the auto-requeued
        # replacement below pick back up instead of starting over. Only an
        # explicit queue-cancel.sh, or a clean finish + verified upload,
        # deletes local files.
        rm -f "$mf"
        handle_interrupted_backup "$id" "$mailbox" "$from" "$to" \
            "backup failed (exit $backup_exit) - $copied/$total item(s) already copied"
        return
    fi

    # Backup succeeded - fold its counts in now; whatever happens next
    # (deferral, upload success, or upload failure) all keep these.
    atomic_jq_update "$jf" '
        .items_expected = $expected
        | .items_copied  = $copied
        | .items_skipped = $skipped
        | .note = (if ($skipped > 0)
                   then "skipped ~\($skipped) item(s) that could not be retrieved after retrying - see log for details"
                   else .note end)' \
        --argjson expected "$m_expected" --argjson copied "$m_copied" --argjson skipped "$m_skipped"
    rm -f "$mf"

    if mailbox_has_pending_backup_sibling "$mailbox" "$id"; then
        atomic_jq_update "$jf" '
            .status = "done" | .exit_code = 0 | .phase = "backup" | .finished_at = $now
            | .note = (if .note then (.note + " (upload deferred until sibling chunk(s) for this mailbox finish)")
                       else "upload deferred until sibling chunk(s) for this mailbox finish" end)' \
            --arg now "$(now_iso)"
        log "Job $id ($mailbox) backup done - other chunk(s) for this mailbox still pending, upload deferred."
        rm -f "$(running_marker "$id")"
        return
    fi

    # --- upload phase (same job, same log, no separate queue entry) --------
    log "Job $id ($mailbox) backup done - no other chunks pending, starting upload."
    atomic_jq_update "$jf" '.phase = "uploading"'

    "$UPLOAD_SCRIPT" "$mailbox" >> "$lf" 2>&1 &
    pid=$!
    atomic_jq_update "$jf" '.pid = $pid' --argjson pid "$pid"

    set +e
    wait "$pid"
    upload_exit=$?
    set -e

    cancel_requested=$(jq -r '.cancel_requested' "$jf")
    if [ "$cancel_requested" = "true" ]; then
        log "Job $id ($mailbox) was cancelled during upload."
        rm -f "$(running_marker "$id")"
        return
    fi

    if [ "$upload_exit" -eq 0 ]; then
        atomic_jq_update "$jf" '.status = "done" | .exit_code = 0 | .phase = "done" | .finished_at = $now' \
            --arg now "$(now_iso)"
        log "Job $id ($mailbox) done (backup + upload)."
    else
        # Upload failed after a successful backup - upload-mailbox-backup.sh
        # already deliberately keeps local files on a failed/unverified
        # upload (they're the only existing copy of that data), so nothing
        # is deleted here, same rationale as the old standalone upload job.
        atomic_jq_update "$jf" '
            .status = "failed" | .exit_code = $ec | .phase = "uploading" | .finished_at = $now
            | .note = (if .note then (.note + " Additionally, upload failed after a successful backup - local backup file(s) kept for retry, see log.")
                       else "Upload failed after a successful backup - local backup file(s) kept for retry, see log." end)
            | .will_retry = false | .next_job_id = null' \
            --argjson ec "$upload_exit" --arg now "$(now_iso)"
        log "Job $id ($mailbox) backup succeeded but upload FAILED (exit $upload_exit) - local files kept, see $lf"
    fi

    rm -f "$(running_marker "$id")"
}

log "Entering claim loop."
while :; do
    # queue-maintenance.sh sets this right before a controlled restart (e.g.
    # to pick up an OS library upgrade) and only removes it once that
    # restart has happened - never claim a new job while it's present. A job
    # already running when the flag appears is left alone; only NEW claims
    # are held back, so the wait is bounded by whatever's already running,
    # not the rest of the backlog behind it.
    if [ -e "$MAINTENANCE_PAUSE_FLAG" ]; then
        sleep 5
        continue
    fi

    next=$(ls -1 "$PENDING_DIR" 2>/dev/null | sort | head -n1 || true)
    if [ -z "$next" ]; then
        sleep 2
        continue
    fi

    if mv "$PENDING_DIR/$next" "$RUNNING_DIR/$next" 2>/dev/null; then
        run_job "$next"
    fi
    # mv failing just means queue-cancel.sh deleted the pending marker first
    # (job was cancelled before the worker got to it) - loop again either way.
done
