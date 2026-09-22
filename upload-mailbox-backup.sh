#!/usr/bin/env bash
# Uploads a mailbox's backup to Dropbox via rclone, then deletes the local
# file(s) once the upload is verified. If there's only one PST chunk, it's
# uploaded as-is (no zip). If there are multiple chunks, they're zipped
# together first so the upload is a single file.
#
# This is deliberately separate from backup-mailbox.sh: run it once, by hand,
# after ALL the chunked backup-mailbox.sh runs for a mailbox have finished
# (e.g. after backing up 2022, 2023, 2024, 2025 separately for a 100GB
# mailbox) - not automatically, and not per-chunk.
#
# Usage:
#   ./upload-mailbox-backup.sh someone@example.com
set -euo pipefail

mailbox="${1:-}"
if [ -z "$mailbox" ]; then
    echo "Usage: $0 <mailbox>" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config_file="$script_dir/rclone-upload.env"

if [ ! -f "$config_file" ]; then
    echo "Missing $config_file - copy rclone-upload.env.example to rclone-upload.env and fill in RCLONE_REMOTE/DROPBOX_FOLDER." >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$config_file"

: "${RCLONE_REMOTE:?RCLONE_REMOTE not set in $config_file}"
: "${DROPBOX_FOLDER:?DROPBOX_FOLDER not set in $config_file}"

backup_dir="${M365_BACKUP_DIR:-/data/backups}"

# Matches every chunk for this mailbox: a plain <mailbox>.pst (unchunked run),
# date-labeled chunks like <mailbox>[JAN2023-DEC2023].pst, and any
# PstChunkWriter size-based -part2/-part3/... split of either.
shopt -s nullglob
chunk_files=("$backup_dir/$mailbox"*.pst)
shopt -u nullglob

if [ ${#chunk_files[@]} -eq 0 ]; then
    echo "No .pst files found for '$mailbox' in $backup_dir - nothing to upload." >&2
    exit 1
fi

echo "Found ${#chunk_files[@]} PST file(s) for $mailbox:"
printf '  %s\n' "${chunk_files[@]}"
echo ""

# Only zip when there's actually more than one file to combine - a single
# chunk (or an unchunked <mailbox>.pst) uploads as-is, under its own name.
created_zip=false
if [ "${#chunk_files[@]}" -eq 1 ]; then
    upload_path="${chunk_files[0]}"
    echo "Only one PST file - uploading it directly, no zip needed."
else
    upload_path="$backup_dir/$mailbox.zip"
    rm -f "$upload_path"
    echo "Zipping ${#chunk_files[@]} files into $upload_path ..."
    zip -j -q "$upload_path" "${chunk_files[@]}"
    created_zip=true
fi

# Never overwrite an existing file of the same name already in Dropbox -
# append " (1)", " (2)", ... (matching how browsers/OSes handle a name
# collision) until we find a name that isn't already there.
local_name="$(basename "$upload_path")"
base_name="${local_name%.*}"
extension="${local_name##*.}"

existing_remote_files="$(rclone lsf "$RCLONE_REMOTE:$DROPBOX_FOLDER" 2>/dev/null || true)"

remote_name="$local_name"
suffix=1
while grep -Fxq "$remote_name" <<< "$existing_remote_files"; do
    remote_name="${base_name} (${suffix}).${extension}"
    suffix=$((suffix + 1))
done

if [ "$remote_name" != "$local_name" ]; then
    echo "'$local_name' already exists in Dropbox - uploading as '$remote_name' instead."
    # rclone check (below) matches source vs. destination by identical
    # relative path/name, so the local file has to be renamed to match the
    # de-duplicated remote name - otherwise verification would look for a
    # local file named $remote_name, not find it (it's still $local_name),
    # and report a false "missing" difference even though the upload worked.
    renamed_path="$backup_dir/$remote_name"
    mv "$upload_path" "$renamed_path"
    upload_path="$renamed_path"
fi

remote_path="$RCLONE_REMOTE:$DROPBOX_FOLDER/$remote_name"
echo "Uploading to $remote_path ..."
rclone copyto "$upload_path" "$remote_path" --progress

echo ""
echo "Verifying upload (checksum comparison)..."
# rclone check compares directories, not bare files, so point it at the
# parent dirs and filter down to just the file we uploaded.
if ! rclone check "$backup_dir" "$RCLONE_REMOTE:$DROPBOX_FOLDER" --include "/$remote_name" --one-way; then
    echo "Upload verification FAILED - keeping all local files, deleting nothing." >&2
    exit 1
fi

if [ "$created_zip" = true ]; then
    echo "Upload verified. Deleting local chunk file(s) and zip..."
    rm -f "${chunk_files[@]}" "$upload_path"
else
    echo "Upload verified. Deleting local file..."
    rm -f "$upload_path"
fi

echo ""
echo "Done. $mailbox backup is now at $remote_path (local copies removed)."
