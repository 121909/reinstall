#!/bin/sh
# Periodically persist filtered Debian Installer diagnostics through boot-trace.
# Runs only when boot_trace is enabled; never mounts or writes NTFS directly.

TRACE_HELPER=${DIAG_TRACE_HELPER:-/lib/debian-installer/boot-trace.sh}
. "$TRACE_HELPER" 2>/dev/null || exit 0

SYSLOG_FILES=${DIAG_SYSLOG_FILES:-"/var/log/syslog /var/log/installer/syslog"}
QUESTIONS_FILES=${DIAG_QUESTIONS_FILES:-"/var/lib/cdebconf/questions.dat /var/log/installer/cdebconf/questions.dat"}
INTERVAL=${DIAG_INTERVAL:-60}

sanitize() {
    sed -E \
        -e 's/(bearer[ ]+)[^ ,;|\"]+/\1[REDACTED]/Ig' \
        -e 's/(authorization|jwt|token|password|passwd|secret|authcode)([=: ]+)[^ ,;|\"]+/\1\2[REDACTED]/Ig' \
        -e 's#https?://[^ ]+# [URL-REDACTED] #Ig' \
        -e 's/[[:cntrl:]]/ /g' \
        | tr '\r\n' '  ' \
        | cut -c1-3500
}

collect_syslog() {
    for file in $SYSLOG_FILES; do
        [ -r "$file" ] || continue
        grep -Ei 'netcfg|network-preseed|debian\.cfg|preseed|main-menu|anna|sshd|dropbear|frpc|poweroff|shutdown|reboot|error|failed' "$file" 2>/dev/null | tail -n 30
    done | sanitize
}

collect_debconf_names() {
    for file in $QUESTIONS_FILES; do
        [ -r "$file" ] || continue
        awk 'BEGIN { RS=""; ORS="; " }
            {
                name=""; flags=""
                n=split($0, lines, "\n")
                for (i=1; i<=n; i++) {
                    if (lines[i] ~ /^Name: /) name=substr(lines[i], 7)
                    if (lines[i] ~ /^Flags: /) flags=substr(lines[i], 8)
                }
                if (name ~ /^(netcfg|debian-installer|preseed|anna|main-menu)\//)
                    print name "[flags=" flags "]"
            }' "$file" 2>/dev/null
    done | tr '\r\n' '  ' | cut -c1-1500
}

snapshot() {
    syslog=$(collect_syslog)
    debconf=$(collect_debconf_names)
    trace_stage DIAG_SYSLOG "${syslog:-no_matching_syslog}" || true
    trace_stage DIAG_DEBCONF "${debconf:-no_matching_debconf_questions}" || true
}

snapshot
[ "${DIAG_ONCE:-0}" = 1 ] && exit 0

case "$INTERVAL" in
    ''|*[!0-9]*) INTERVAL=60 ;;
esac
[ "$INTERVAL" -lt 10 ] && INTERVAL=10
while :; do
    sleep "$INTERVAL"
    snapshot
done
