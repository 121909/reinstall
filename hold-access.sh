#!/bin/sh
# Start the hold-only access services from files already present in the initrd.
# Status only: /tmp/hold-access.log contains sanitized startup messages;
# daemon stdout/stderr (which may contain config diagnostics) stays under
# /run/hold-access/ mode 0700 and is never copied to trace output.
# This script never downloads configuration or credentials and never prints them.
set -f
umask 077
# Also close debconf descriptors when called without the netcfg wrapper.
exec </dev/null 3>&- 4>&- 5>&- 6>&-

mkdir -p /run/hold-access || exit 1
chmod 700 /run/hold-access 2>/dev/null || exit 1
log=/tmp/hold-access.log
: >>"$log" || exit 1
chmod 600 "$log" 2>/dev/null || exit 1
say() {
    printf '[hold-access] %s\n' "$*" >>"$log"
}
fatal() {
    say "ERROR: $*"
    exit 1
}

# Only reuse the process created by this hook, never an unrelated sshd/frpc.
running() {
    [ -r "$1" ] || return 1
    read -r service_pid <"$1" || return 1
    case "$service_pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$(readlink "/proc/$service_pid/exe" 2>/dev/null)" = "$2" ] || return 1
    kill -0 "$service_pid" 2>/dev/null
}

# Parse only the two supported extra_* values.  Do not eval kernel parameters.
username=root
ssh_port=22
for arg in $(cat /proc/cmdline 2>/dev/null); do
    case "$arg" in
        extra_username=*) username=${arg#extra_username=} ;;
        extra_ssh_port=*) ssh_port=${arg#extra_ssh_port=} ;;
    esac
done

# The initrd has no account-management prerequisite.  Root with a pre-provisioned
# authorized key is the only supported account; anything else fails closed.
[ "$username" = root ] || fatal "unsupported username (only root is accepted)"
case "$ssh_port" in
    ''|*[!0-9]*) fatal "invalid SSH port" ;;
esac
[ "$ssh_port" -ge 1 ] 2>/dev/null && [ "$ssh_port" -le 65535 ] || fatal "SSH port outside 1..65535"

key_source=/configs/ssh_keys
[ -s "$key_source" ] || fatal "the pre-provisioned SSH key file is unavailable"

# Installer root's home is /, not /root.  Refuse an incompatible account rather
# than rewriting its password, home, shell, or existing authorized_keys files.
root_home=
while IFS=: read -r name password uid gid gecos home shell; do
    [ "$name" = root ] || continue
    [ "$uid" = 0 ] && [ "$gid" = 0 ] && [ "$home" = / ] && [ "$shell" = /bin/sh ] || fatal "unsupported initrd root account"
    root_home=$home
done </etc/passwd
[ "$root_home" = / ] || fatal "initrd root account is unavailable"

# OpenSSH privilege separation needs its unprivileged account.  No login account
# or password is created; all pre-existing account and shadow entries are kept.
if ! grep -q '^sshd:' /etc/passwd; then
    printf 'sshd:*:100:65534::/run/sshd:/bin/false\n' >>/etc/passwd || fatal "cannot create sshd account"
fi
if ! grep -q '^[^:]*:[^:]*:65534:' /etc/group; then
    printf 'nogroup:x:65534:\n' >>/etc/group || fatal "cannot create sshd group"
fi

[ -x /usr/sbin/sshd ] || fatal "sshd is not present in the initrd"
[ -x /usr/bin/ssh-keygen ] || fatal "ssh-keygen is not present in the initrd"
mkdir -p /etc/ssh /run/sshd || fatal "cannot create sshd configuration/runtime directories"
# Windows-packed cpio directories carry non-root IDs; StrictModes checks ancestors.
chown 0:0 / /etc/ssh /run/sshd /configs /configs/ssh_keys 2>/dev/null || fatal "cannot secure SSH path ownership"
chmod 755 /run/sshd /configs /etc/ssh 2>/dev/null || fatal "cannot secure SSH directory modes"
chmod 600 /configs/ssh_keys 2>/dev/null || fatal "cannot secure authorized key mode"
/usr/bin/ssh-keygen -A >/dev/null 2>&1 || fatal "host-key generation failed"

# Do not rewrite /etc/ssh/sshd_config, host keys, or source configuration.  Use a
# separate explicit key-only policy: Include/Match directives from other configs
# must not override the hold authentication boundary.  Locked accounts stay
# locked; password-only access and arbitrary usernames are intentionally unsupported.
sshd_config=/run/hold-access/sshd_config
cat >"$sshd_config" <<EOF
# Local hold access; credentials remain in the pre-provisioned key file.
Port $ssh_port
PidFile /run/hold-access/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitRootLogin prohibit-password
AllowUsers root
AuthorizedKeysFile /configs/ssh_keys /.ssh/authorized_keys
StrictModes yes
EOF

/usr/sbin/sshd -t -f "$sshd_config" >/dev/null 2>&1 || fatal "sshd configuration validation failed"
if running /run/hold-access/sshd.pid /usr/sbin/sshd; then
    say "local hold sshd already running"
else
    if pidof sshd >/dev/null 2>&1; then
        fatal "unmanaged sshd is already running; refusing a second listener"
    fi
    /usr/sbin/sshd -D -e -f "$sshd_config" >>/run/hold-access/sshd.log 2>&1 &
    sshd_pid=$!
    sleep 1
    kill -0 "$sshd_pid" 2>/dev/null || fatal "sshd exited during startup"
    printf '%s\n' "$sshd_pid" >/run/hold-access/sshd.pid
    say "sshd started on configured port (pid=$sshd_pid)"
fi

# frpc is deliberately an initrd-provided executable.  No package or URL fetch
# is attempted here; its existing config remains the source of all credentials.
frpc_config=/configs/frpc.conf
[ -s "$frpc_config" ] || fatal "the pre-provisioned frpc config is unavailable"
[ -x /usr/local/bin/frpc ] || fatal "frpc executable is not present in the initrd"
if running /run/hold-access/frpc.pid /usr/local/bin/frpc; then
    say "local hold frpc already running"
else
    if pidof frpc >/dev/null 2>&1; then
        fatal "unmanaged frpc is already running; refusing a second client"
    fi
    /usr/local/bin/frpc -c "$frpc_config" >>/run/hold-access/frpc.log 2>&1 &
    frpc_pid=$!
    sleep 1
    kill -0 "$frpc_pid" 2>/dev/null || fatal "frpc exited during startup"
    printf '%s\n' "$frpc_pid" >/run/hold-access/frpc.pid
    say "frpc started (pid=$frpc_pid; credentials omitted)"
fi

say "local hold access startup complete"
exit 0
