#!/usr/bin/env bash
# Runs daily via a systemd timer, once the queue is idle: installs pending
# package upgrades, then restarts the queue service so any library upgrade
# needing a restart gets picked up at a controlled time instead of mid-job.
# Anything that needs an actual reboot (e.g. a new kernel) is left for the
# weekly window (queue-weekly-reboot.sh) - this one only restarts the
# service, never the host.
#
# Sets MAINTENANCE_PAUSE_FLAG so the worker's claim loop stops picking up
# NEW jobs, waits for whatever's already running to finish on its own (no
# forced kill - a backup job resumes automatically after an interruption,
# see Program.cs's ResumeState/queue-lib.sh's handle_interrupted_backup),
# restarts the service once idle, then clears the flag.
#
# Must run as root - only root can apt-get/restart a systemd service.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/queue-lib.sh"

log() { echo "[$(now_iso)] $*"; }

log "Maintenance pass starting - pausing new job claims."
touch "$MAINTENANCE_PAUSE_FLAG"

waited=0
while any_running_jobs; do
    if [ $((waited % 900)) -eq 0 ]; then
        running_id=$(find "$RUNNING_DIR" -mindepth 1 -maxdepth 1 -not -name '.gitkeep' | head -n1 | xargs -r basename)
        mailbox=$(mailbox_for_job "$running_id" 2>/dev/null || echo "?")
        log "Still waiting on job $running_id ($mailbox) to finish (${waited}s so far) - no forced cancel, just holding off the restart."
    fi
    sleep 15
    waited=$((waited + 15))
done

log "Queue is idle - installing any pending upgrades."
export DEBIAN_FRONTEND=noninteractive
# Lock::Timeout so a concurrent apt lock-holder makes this wait rather than
# fail outright; if apt still errors, `set -e` stops the script here and the
# restart below is simply skipped for today, tried again tomorrow.
apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 -y dist-upgrade

log "Restarting m365backup-queue.service."
systemctl restart m365backup-queue.service

rm -f "$MAINTENANCE_PAUSE_FLAG"
log "Maintenance pass done - new job claims resumed."
