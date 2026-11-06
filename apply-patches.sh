#!/bin/sh
set -e
target_initrd_dir="$1"
if [ -z "$target_initrd_dir" ] || [ ! -d "$target_initrd_dir" ]; then
    echo "Usage: apply-patches.sh <initrd_dir>" >&2
    exit 1
fi

patch_src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -f "$patch_src/boot-trace.sh" ]; then
    patch_src="/cygdrive/c/cygwin/reinstall-patches"
    [ ! -d "$patch_src" ] && patch_src="/reinstall-patches"
fi

echo "Applying local patches to $target_initrd_dir from $patch_src..."

# 1. Overwrite network and udhcpc scripts with local verified versions
if [ -f "$patch_src/initrd-network.sh" ]; then
    cp -f "$patch_src/initrd-network.sh" "$target_initrd_dir/initrd-network.sh"
    chmod 755 "$target_initrd_dir/initrd-network.sh"
fi
if [ -f "$patch_src/trans.sh" ] && grep -q "TRANS_IFUPDOWN" "$patch_src/trans.sh"; then
    cp -f "$patch_src/trans.sh" "$target_initrd_dir/trans.sh"
    chmod 755 "$target_initrd_dir/trans.sh"
fi

if [ -f "$patch_src/default.script" ]; then
    mkdir -p "$target_initrd_dir/etc/udhcpc"
    cp -f "$patch_src/default.script" "$target_initrd_dir/etc/udhcpc/default.script"
    chmod 755 "$target_initrd_dir/etc/udhcpc/default.script"
fi
# 2. Install ntfs-3g and boot-trace
mkdir -p "$target_initrd_dir/usr/bin" "$target_initrd_dir/usr/lib/debian-installer" "$target_initrd_dir/usr/lib/x86_64-linux-gnu" "$target_initrd_dir/usr/sbin"
cp -f "$patch_src/boot-trace.sh" "$target_initrd_dir/usr/lib/debian-installer/boot-trace.sh"
chmod 755 "$target_initrd_dir/usr/lib/debian-installer/boot-trace.sh"
cp -f "$patch_src/boot-trace" "$target_initrd_dir/usr/bin/boot-trace"
chmod 755 "$target_initrd_dir/usr/bin/boot-trace"
cp -f "$patch_src/offline-diag-export.sh" "$target_initrd_dir/usr/lib/debian-installer/offline-diag-export.sh"
chmod 755 "$target_initrd_dir/usr/lib/debian-installer/offline-diag-export.sh"

if [ -f "$patch_src/ntfs-3g" ]; then
    cp -f "$patch_src/ntfs-3g" "$target_initrd_dir/usr/bin/ntfs-3g"
    chmod 755 "$target_initrd_dir/usr/bin/ntfs-3g"
    ln -sf ../bin/ntfs-3g "$target_initrd_dir/usr/sbin/mount.ntfs-3g"
    ln -sf mount.ntfs-3g "$target_initrd_dir/usr/sbin/mount.ntfs"
fi
if [ -f "$patch_src/libntfs-3g.so.89" ] && [ -f "$patch_src/libntfs-3g.so.89.0.0" ]; then
    cp -f "$patch_src/libntfs-3g.so.89" "$target_initrd_dir/usr/lib/libntfs-3g.so.89"
    cp -f "$patch_src/libntfs-3g.so.89.0.0" "$target_initrd_dir/usr/lib/libntfs-3g.so.89.0.0"
    cp -f "$patch_src/libntfs-3g.so.89" "$target_initrd_dir/usr/lib/x86_64-linux-gnu/libntfs-3g.so.89"
    cp -f "$patch_src/libntfs-3g.so.89.0.0" "$target_initrd_dir/usr/lib/x86_64-linux-gnu/libntfs-3g.so.89.0.0"
fi

# 2.1 Install virtio_blk storage module and updated modules metadata
mkdir -p "$target_initrd_dir/usr/lib/modules/6.12.107+deb13-amd64/kernel/drivers/block"
if [ -f "$patch_src/virtio_blk.ko.xz" ]; then
    cp -f "$patch_src/virtio_blk.ko.xz" "$target_initrd_dir/usr/lib/modules/6.12.107+deb13-amd64/kernel/drivers/block/virtio_blk.ko.xz"
fi
if [ -d "$patch_src/modules-6.12.107+deb13-amd64" ]; then
    cp -f "$patch_src/modules-6.12.107+deb13-amd64"/* "$target_initrd_dir/usr/lib/modules/6.12.107+deb13-amd64/"
fi

# 2.2 Offline hold access: all executables/configuration are available before preseed.
mkdir -p "$target_initrd_dir/usr/local/bin" "$target_initrd_dir/var/lib/dpkg/info"
cp -f "$patch_src/hold-access.sh" "$target_initrd_dir/usr/lib/debian-installer/hold-access.sh"
cp -f "$patch_src/hold-preseed.cfg" "$target_initrd_dir/usr/lib/debian-installer/hold-preseed.cfg"
cp -f "$patch_src/network-preseed.postinst" "$target_initrd_dir/var/lib/dpkg/info/network-preseed.postinst"
chmod 755 "$target_initrd_dir/usr/lib/debian-installer/hold-access.sh" \
    "$target_initrd_dir/var/lib/dpkg/info/network-preseed.postinst"
if [ -f "$patch_src/frpc" ]; then
    cp -f "$patch_src/frpc" "$target_initrd_dir/usr/local/bin/frpc"
    chmod 755 "$target_initrd_dir/usr/local/bin/frpc"
fi
chmod 644 "$target_initrd_dir/usr/lib/debian-installer/hold-preseed.cfg"
# 3. Inject trace hooks into /init if not present
if [ -f "$target_initrd_dir/init" ] && ! grep -q "INIT_START" "$target_initrd_dir/init"; then
    sed -i '/mount \/sys/a \
. /lib/debian-installer/boot-trace.sh 2>/dev/null || true\
trace_stage INIT_START "Kernel $(uname -r) booted; cmdline: $(cat /proc/cmdline 2>/dev/null)" || true' "$target_initrd_dir/init"
    sed -i '/\/lib\/debian-installer\/start-udev/i \
depmod -a 2>/dev/null || true' "$target_initrd_dir/init"
    sed -i '/\/lib\/debian-installer\/start-udev/a \
trace_stage UDEV_SETTLED "Udev settled; blocks: $(ls /sys/class/block 2>/dev/null | tr '"'\\n'"' '"' '"'); net: $(ls /sys/class/net 2>/dev/null | tr '"'\\n'"' '"' '"')" || true' "$target_initrd_dir/init"
fi

# 4. Inject trace hooks into debian-installer-startup if not present
if [ -f "$target_initrd_dir/usr/sbin/debian-installer-startup" ] && ! grep -q "STARTUP_ENTER" "$target_initrd_dir/usr/sbin/debian-installer-startup"; then
    sed -i '2a \
. /lib/debian-installer/boot-trace.sh 2>/dev/null || true\
trace_stage STARTUP_ENTER "Running debian-installer-startup scripts" || true' "$target_initrd_dir/usr/sbin/debian-installer-startup"
    echo 'trace_stage STARTUP_DONE "Completed debian-installer-startup scripts" || true' >> "$target_initrd_dir/usr/sbin/debian-installer-startup"
fi

# 5. Inject trace hooks into netcfg.postinst if not present
if [ -f "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst" ] && ! grep -q "NET_PRE" "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst"; then
    sed -i '/: get_ip_conf_cmd;/a \
    . /lib/debian-installer/boot-trace.sh 2>/dev/null || true\
    trace_stage NET_PRE "Starting network config; interfaces: $(ip -br link 2>/dev/null | tr '"'\\n'"' '"'; '"')" || true' "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst"
    sed -i '/db_progress INFO base-installer\/progress\/netcfg/i \
    trace_stage NET_POST "Network configured; addrs: $(ip -br addr 2>/dev/null | tr '"'\\n'"' '"'; '"'); routes: $(ip route 2>/dev/null | tr '"'\\n'"' '"'; '"'); resolv: $(cat /etc/resolv.conf 2>/dev/null | tr '"'\\n'"' '"'; '"')" || true' "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst"
    sed -i '/sh \/trans.sh || exit/i \
    trace_stage TRANS_PRE "About to run trans.sh" || true' "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst"
    sed -i '/sh \/trans.sh || exit/a \
    trace_stage TRANS_POST "trans.sh returned $?" || true' "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst"
    echo '    trace_stage NETCFG_DONE "netcfg.postinst finished successfully" || true' >> "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst"
fi
if [ -f "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst" ] && ! grep -q "STORAGE_READY" "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst"; then
    cat <<'EOF' >> "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst"
    # Ensure virtio_blk storage driver is loaded for UUID-guarded boot-trace
    modprobe virtio_blk 2>/dev/null || true
    vda_info=$(ls -l /dev/vda* 2>/dev/null | tr '\n' '; ')
    trace_stage STORAGE_READY "/dev/vda: ${vda_info:-absent}" || true
EOF
fi
if [ -f "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst" ] && ! grep -q "OFFLINE_DIAG_EXPORT" "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst"; then
    cat <<'EOF' >> "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst"
    # Persist filtered diagnostics without requiring SSH access.
    if grep -qw "boot_trace=1" /proc/cmdline 2>/dev/null || grep -qw "boot_trace" /proc/cmdline 2>/dev/null; then
        /usr/lib/debian-installer/offline-diag-export.sh </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- &
        trace_stage OFFLINE_DIAG_EXPORT "Filtered diagnostics exporter started" || true
    fi
EOF
fi
if [ -f "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst" ] && ! grep -q "HOLD_ACCESS" "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst"; then
    cat <<'EOF' >> "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst"
    # Hold access is started locally before network-preseed; no remote config is needed.
    if grep -qE '(^|[[:space:]])(hold|extra_hold)=1([[:space:]]|$)' /proc/cmdline 2>/dev/null; then
        if /usr/lib/debian-installer/hold-access.sh >>/tmp/hold-access.log 2>&1; then
            trace_stage HOLD_ACCESS "Local SSH/frpc startup requested; details in /tmp/hold-access.log (credentials omitted)" || true
        else
            trace_stage HOLD_ACCESS_ERROR "Local SSH/frpc startup failed; details in /tmp/hold-access.log (credentials omitted)" || true
        fi
    fi
EOF
fi

# 6. Inject trace hooks into trans.sh main if not present
if [ -f "$target_initrd_dir/trans.sh" ] && ! grep -q "TRANS_MAIN" "$target_initrd_dir/trans.sh"; then
    sed -i '/^: main/a \
        . /lib/debian-installer/boot-trace.sh 2>/dev/null || true\
        trace_stage TRANS_MAIN "trans.sh main invoked; generating network interfaces" || true' "$target_initrd_dir/trans.sh"
fi

# 7. Normalize LF line endings on all modified scripts/configs
for lf_file in \
    "$target_initrd_dir/init" \
    "$target_initrd_dir/initrd-network.sh" \
    "$target_initrd_dir/trans.sh" \
    "$target_initrd_dir/etc/udhcpc/default.script" \
    "$target_initrd_dir/usr/bin/boot-trace" \
    "$target_initrd_dir/usr/sbin/debian-installer-startup" \
    "$target_initrd_dir/usr/lib/debian-installer/boot-trace.sh" \
    "$target_initrd_dir/usr/lib/debian-installer/offline-diag-export.sh" \
    "$target_initrd_dir/usr/lib/debian-installer/hold-access.sh" \
    "$target_initrd_dir/usr/lib/debian-installer/hold-preseed.cfg" \
    "$target_initrd_dir/var/lib/dpkg/info/netcfg.postinst" \
    "$target_initrd_dir/var/lib/dpkg/info/network-preseed.postinst"; do
    [ -f "$lf_file" ] && sed -i 's/\r$//' "$lf_file"
done

echo "Local patches applied successfully to $target_initrd_dir."
