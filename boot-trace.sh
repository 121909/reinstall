#!/bin/sh
# /lib/debian-installer/boot-trace.sh
# Minimal safe boot trace logger for Debian installer environment.
# Safety invariants:
# 1. Target volume strictly identified by NTFS UUID: D682BDCE82BDB37B (Windows C:).
# 2. Never writes to System Reserved partition (Partition 1).
# 3. Controlled by kernel cmdline boot_trace=1 or boot_trace.
# 4. Mounts strictly with: rw,noatime,sync,norecover.
#    - 'norecover': Refuses write access if filesystem was not cleanly unmounted by Windows.
#    - No -o force: Never forces mounting of dirty/hibernated volumes.
#    - No --remove_hiberfile: Never tampers with Windows hibernation state.
# 5. Write probe: Tests writability before committing (handles norecover ro fallback).
# 6. Atomic flush: Only advances flushed line counter if write AND sync succeed AND umount cleanly succeeds.
# 7. Persistent lock file (/tmp/reinstall-trace-disk-disabled.lock): Locks out writes across processes if umount fails.
# 8. Mount conflict check: Refuses to touch or unmount a mountpoint already mounted by another process.
# 9. Dual blkid compatibility: Works with both util-linux blkid and BusyBox blkid.

TRACE_LOG_MEM="/tmp/reinstall-trace.log"
TRACE_FLUSHED_FILE="/tmp/reinstall-trace.flushed"
TRACE_LOCK_FILE="/tmp/reinstall-trace-disk-disabled.lock"
TRACE_LOG_NAME="reinstall-trace.log"
cmd_uuid=$(grep -o 'target_ntfs_uuid=[^ ]*' /proc/cmdline 2>/dev/null | cut -d= -f2 | tr 'a-z' 'A-Z')
TARGET_NTFS_UUID="${cmd_uuid:-D682BDCE82BDB37B}"

is_boot_trace_enabled() {
    # Check /proc/cmdline for boot_trace=1 or boot_trace
    grep -qw "boot_trace=1" /proc/cmdline 2>/dev/null || grep -qw "boot_trace" /proc/cmdline 2>/dev/null
}

get_dev_prop() {
    local dev="$1"
    local prop="$2"

    # 1. Try util-linux blkid with -s and -o value
    local val
    val=$(blkid -s "$prop" -o value "$dev" 2>/dev/null)
    if [ -n "$val" ]; then
        echo "$val"
        return 0
    fi

    # 2. Fallback to parsing raw blkid output (BusyBox blkid compatibility)
    # Format: /dev/xxx: UUID="yyy" LABEL="zzz" TYPE="ntfs"
    blkid "$dev" 2>/dev/null | grep -o "$prop=\"[^\"]*\"" | head -n 1 | cut -d'"' -f2
}

find_target_windows_ntfs_part() {
    # 1. Enumerate block devices from blkid
    local candidate
    for candidate in $(blkid 2>/dev/null | cut -d: -f1); do
        local fstype
        fstype=$(get_dev_prop "$candidate" "TYPE")
        if [ "$fstype" = "ntfs" ]; then
            local uuid
            uuid=$(get_dev_prop "$candidate" "UUID" | tr 'a-z' 'A-Z')
            if [ "$uuid" = "$TARGET_NTFS_UUID" ]; then
                local label
                label=$(get_dev_prop "$candidate" "LABEL")
                case "$label" in
                    *"System Reserved"*|*"系统保留"*)
                        continue
                        ;;
                esac
                echo "$candidate"
                return 0
            fi
        fi
    done

    # 2. Check /dev/disk/by-uuid symlinks with strict property verification
    for u in "$TARGET_NTFS_UUID" "$(echo "$TARGET_NTFS_UUID" | tr 'A-Z' 'a-z')"; do
        local link="/dev/disk/by-uuid/$u"
        if [ -b "$link" ]; then
            local real_part
            real_part=$(readlink -f "$link" 2>/dev/null || echo "$link")
            local fstype
            fstype=$(get_dev_prop "$real_part" "TYPE")
            local uuid
            uuid=$(get_dev_prop "$real_part" "UUID" | tr 'a-z' 'A-Z')
            local label
            label=$(get_dev_prop "$real_part" "LABEL")
            if [ "$fstype" = "ntfs" ] && [ "$uuid" = "$TARGET_NTFS_UUID" ]; then
                case "$label" in
                    *"System Reserved"*|*"系统保留"*)
                        continue
                        ;;
                esac
                echo "$real_part"
                return 0
            fi
        fi
    done

    # Strict: If exact UUID match cannot be confirmed, return failure.
    return 1
}

flush_trace_buffer_to_disk() {
    # Check persistent lock file across processes
    if [ -f "$TRACE_LOCK_FILE" ]; then
        return 0
    fi

    local part
    part=$(find_target_windows_ntfs_part)
    if [ -z "$part" ]; then
        # Target partition not available or unverified; keep in memory
        return 0
    fi

    # Ensure FUSE character device exists
    if [ ! -c /dev/fuse ]; then
        mknod -m 0666 /dev/fuse c 10 229 2>/dev/null || true
    fi

    local mnt="/mnt/trace_win"

    # Safety: Refuse to mount or touch if mountpoint is already in use by another process
    if grep -E -q "[[:space:]]$mnt[[:space:]]" /proc/mounts 2>/dev/null; then
        echo ">> [TRACE_WARN] Mountpoint $mnt is already occupied; refusing to intervene." >&2
        return 0
    fi

    mkdir -p "$mnt" 2>/dev/null || true

    # Safe mount with norecover:
    # Denies write access if the volume was not cleanly unmounted by Windows.
    # Never use -o force or --remove_hiberfile.
    if ntfs-3g "$part" "$mnt" -o rw,noatime,sync,norecover 2>/dev/null; then
        # 1. Verify filesystem is actually writable (handles norecover ro fallback)
        if ! touch "$mnt/.write_probe" 2>/dev/null; then
            echo ">> [TRACE_WARN] NTFS volume $part mounted read-only (norecover fallback); cannot write, leaving in memory." >&2
            umount "$mnt" 2>/dev/null || true
            return 0
        fi
        rm -f "$mnt/.write_probe" 2>/dev/null || true

        local flushed=0
        if [ -f "$TRACE_FLUSHED_FILE" ]; then
            flushed=$(cat "$TRACE_FLUSHED_FILE" 2>/dev/null || echo 0)
        fi

        local total=0
        if [ -f "$TRACE_LOG_MEM" ]; then
            total=$(wc -l < "$TRACE_LOG_MEM" 2>/dev/null || echo 0)
        fi

        local write_ok=1
        if [ "$total" -gt "$flushed" ]; then
            local start_line=$((flushed + 1))
            # Primary path: root of C:\
            if ! tail -n +"$start_line" "$TRACE_LOG_MEM" >> "$mnt/$TRACE_LOG_NAME" 2>/dev/null; then
                write_ok=0
            fi

            # Secondary path: C:\cygwin\ if directory exists
            if [ -d "$mnt/cygwin" ]; then
                if ! tail -n +"$start_line" "$TRACE_LOG_MEM" >> "$mnt/cygwin/$TRACE_LOG_NAME" 2>/dev/null; then
                    write_ok=0
                fi
            fi

            # Sync check
            if [ "$write_ok" = "1" ]; then
                if ! sync 2>/dev/null; then
                    write_ok=0
                fi
            fi
        fi

        # Strict umount without lazy fallback
        if umount "$mnt" 2>/dev/null; then
            if [ "$write_ok" = "1" ]; then
                # Only advance flushed line counter if write and sync and umount all succeeded
                echo "$total" > "$TRACE_FLUSHED_FILE"
            else
                echo ">> [TRACE_ALERT] Write or sync to $mnt failed! Retaining buffer in memory." >&2
                if [ -w /dev/kmsg ]; then
                    echo "<3>[BOOT_TRACE_ALERT] Write or sync to $part failed; buffer retained." > /dev/kmsg 2>/dev/null || true
                fi
            fi
        else
            echo ">> [TRACE_ALERT] umount $mnt failed! Volume held open. Permanently locking future disk writes." >&2
            if [ -w /dev/kmsg ]; then
                echo "<2>[BOOT_TRACE_ALERT] umount $mnt failed! Volume held open. Engaging permanent lock." > /dev/kmsg 2>/dev/null || true
            fi
            touch "$TRACE_LOCK_FILE"
            return 3
        fi
    else
        # Mount refused: volume is dirty, hibernated, or read-only.
        # Do not force. Log alert and leave filesystem untouched.
        echo ">> [TRACE_WARN] NTFS partition $part mount refused (norecover active); volume protected, log kept in memory." >&2
        if [ -w /dev/kmsg ]; then
            echo "<4>[BOOT_TRACE_WARN] NTFS partition $part mount refused (norecover active); volume protected." > /dev/kmsg 2>/dev/null || true
        fi
    fi
}

trace_stage() {
    # Check if boot trace is enabled on cmdline
    if ! is_boot_trace_enabled; then
        return 0
    fi

    local stage="$1"
    shift
    local msg="$*"

    # Format timestamp
    local ts
    ts=$(date "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
    if [ -z "$ts" ]; then
        local up
        up=$(cat /proc/uptime 2>/dev/null | cut -d' ' -f1)
        ts="uptime:${up:-0}"
    fi

    local logline="[$ts] [$stage] $msg"

    # 1. Output to kernel dmesg ringbuffer
    if [ -w /dev/kmsg ]; then
        echo "<5>[BOOT_TRACE] [$stage] $msg" > /dev/kmsg 2>/dev/null || true
    fi

    # 2. Append to memory log buffer
    echo "$logline" >> "$TRACE_LOG_MEM" 2>/dev/null || true

    # 3. Output to console/stderr
    echo ">> [TRACE] [$stage] $msg" >&2

    # 4. Flush unwritten buffer to disk if target is accessible
    flush_trace_buffer_to_disk || true
}
