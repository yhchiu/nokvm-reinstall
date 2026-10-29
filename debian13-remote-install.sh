#!/usr/bin/env bash
# Debian 13 remote installer bootstrap for machines without KVM/IPMI.
#
# Safety model:
#   - prepare: never reboots and never touches partition tables.
#   - arm:     only sets a one-shot GRUB next_entry.
#   - disarm:  clears the one-shot GRUB next_entry.
#   - cleanup: removes only files/GRUB block created by this script.
#
# The Debian Installer itself remains interactive. You must SSH to the
# network-console and verify networking/storage before writing any disk changes.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION="0.2.0"
DEBIAN_SUITE="trixie"
ENTRY_ID="debian13-remote-installer"
ENTRY_TITLE="Debian 13 Remote Installer"
WORK_DIR="/root/debian13-remote-install"
BOOT_DIR="/boot/debian13-remote-install"
STATE_FILE="$WORK_DIR/state.env"
PASSWORD_FILE="$WORK_DIR/installer-password.txt"
PRESEED_FILE="$WORK_DIR/preseed.cfg"
BACKUP_DIR="$WORK_DIR/system-snapshot"

BASE_URL="https://deb.debian.org/debian/dists/${DEBIAN_SUITE}/main/installer-amd64/current/images"
NETBOOT_REL="netboot/debian-installer/amd64"
NETBOOT_URL="$BASE_URL/$NETBOOT_REL"

MARK_BEGIN="# BEGIN debian13-remote-install"
MARK_END="# END debian13-remote-install"

NETWORK_MODE="static"
IFACE=""
ADDRESS_CIDR=""
GATEWAY=""
DNS_SERVERS=""
INSTALLER_IFACE="auto"
ALLOW_SECURE_BOOT=0
FORCE_NETWORK=0
FORCE_GRUBENV=0
YES=0

log()  { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Debian 13 remote-install bootstrap (no KVM/IPMI)

Usage:
  debian13-remote-install.sh check [options]
  debian13-remote-install.sh prepare [options]
  debian13-remote-install.sh status
  debian13-remote-install.sh arm [--allow-secure-boot] [--force-grubenv]
  debian13-remote-install.sh disarm
  debian13-remote-install.sh cleanup [--yes]

prepare/check options:
  --network static|dhcp    Installer network mode. Default: static
                           "static" clones the current IPv4 config unless
                           overridden by the options below.
  --interface IFACE        Current uplink interface and installer interface.
                           Default: interface used by the IPv4 default route.
  --installer-interface X  d-i netcfg interface selection. Default: auto.
                           Use only when multiple active NICs require it.
  --address IP/PREFIX      Static IPv4, e.g. 203.0.113.50/24
  --gateway IP             Static IPv4 gateway
  --dns "IP IP ..."        Static DNS servers
  --allow-secure-boot      Continue even if Secure Boot is enabled.
                           Unsafe unless the current GRUB/shim trust chain is
                           known to accept the Debian installer kernel.
  --force-network          Allow bridge/bond/VLAN/non-physical uplinks or
                           ambiguous NIC topology. You assume the risk.
  --force-grubenv          Allow one-shot GRUB on a /boot layout where GRUB
                           may be unable to clear next_entry at boot (for
                           example LVM/MDRAID/Btrfs). This weakens rollback.
  --yes                    Skip cleanup confirmation only.

Recommended flow:
  1. ./debian13-remote-install.sh check
  2. ./debian13-remote-install.sh prepare
  3. ./debian13-remote-install.sh status
  4. ./debian13-remote-install.sh arm
  5. reboot
  6. ssh installer@SERVER_IP
  7. In installer shell: verify ip addr / ip route / DNS / lsblk
  8. Only then start the installer and write partition changes.

Examples:
  # Clone current IPv4 settings as static installer settings
  ./debian13-remote-install.sh prepare

  # DHCP installer
  ./debian13-remote-install.sh prepare --network dhcp

  # Explicit static values
  ./debian13-remote-install.sh prepare --network static \
      --interface eno1 \
      --address 203.0.113.50/24 \
      --gateway 203.0.113.1 \
      --dns "1.1.1.1 8.8.8.8"
USAGE
}

need_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root."
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

parse_options() {
    while (($#)); do
        case "$1" in
            --network)
                (($# >= 2)) || die "--network requires a value"
                NETWORK_MODE="$2"; shift 2 ;;
            --interface)
                (($# >= 2)) || die "--interface requires a value"
                IFACE="$2"; INSTALLER_IFACE="$2"; shift 2 ;;
            --installer-interface)
                (($# >= 2)) || die "--installer-interface requires a value"
                INSTALLER_IFACE="$2"; shift 2 ;;
            --address)
                (($# >= 2)) || die "--address requires a value"
                ADDRESS_CIDR="$2"; shift 2 ;;
            --gateway)
                (($# >= 2)) || die "--gateway requires a value"
                GATEWAY="$2"; shift 2 ;;
            --dns)
                (($# >= 2)) || die "--dns requires a value"
                DNS_SERVERS="$2"; shift 2 ;;
            --allow-secure-boot)
                ALLOW_SECURE_BOOT=1; shift ;;
            --force-network)
                FORCE_NETWORK=1; shift ;;
            --force-grubenv)
                FORCE_GRUBENV=1; shift ;;
            --yes|-y)
                YES=1; shift ;;
            -h|--help)
                usage; exit 0 ;;
            *)
                die "Unknown option: $1" ;;
        esac
    done

    case "$NETWORK_MODE" in
        static|dhcp) ;;
        *) die "--network must be static or dhcp" ;;
    esac
}

secure_boot_state() {
    if [[ ! -d /sys/firmware/efi ]]; then
        printf 'not-applicable'
        return
    fi

    if command -v mokutil >/dev/null 2>&1; then
        local out
        out="$(mokutil --sb-state 2>/dev/null || true)"
        case "$out" in
            *enabled*)  printf 'enabled'; return ;;
            *disabled*) printf 'disabled'; return ;;
        esac
    fi

    local f value
    f="$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -n1 || true)"
    if [[ -n "$f" ]] && command -v od >/dev/null 2>&1; then
        value="$(od -An -t u1 -j 4 -N 1 "$f" 2>/dev/null | tr -d ' ' || true)"
        case "$value" in
            1) printf 'enabled'; return ;;
            0) printf 'disabled'; return ;;
        esac
    fi

    printf 'unknown'
}

prefix_to_netmask() {
    local p="$1" i bits octet out=""
    [[ "$p" =~ ^[0-9]+$ ]] || die "Invalid IPv4 prefix: $p"
    (( p >= 0 && p <= 32 )) || die "Invalid IPv4 prefix: $p"

    bits="$p"
    for i in 1 2 3 4; do
        if (( bits >= 8 )); then
            octet=255
            bits=$((bits - 8))
        elif (( bits <= 0 )); then
            octet=0
        else
            octet=$((256 - (1 << (8 - bits))))
            bits=0
        fi
        if [[ -z "$out" ]]; then out="$octet"; else out+=".$octet"; fi
    done
    printf '%s' "$out"
}

is_loopback_dns() {
    case "$1" in
        127.*|::1|0.0.0.0) return 0 ;;
        *) return 1 ;;
    esac
}

collect_dns() {
    local iface="$1" d line token
    local -a found=()

    if command -v resolvectl >/dev/null 2>&1; then
        line="$(resolvectl dns "$iface" 2>/dev/null | head -n1 || true)"
        if [[ "$line" == *:* ]]; then
            line="${line#*:}"
            for token in $line; do
                if ! is_loopback_dns "$token"; then
                    found+=("$token")
                fi
            done
        fi
    fi

    if [[ -r /etc/resolv.conf ]]; then
        while read -r d; do
            [[ -n "${d:-}" ]] || continue
            if ! is_loopback_dns "$d"; then
                found+=("$d")
            fi
        done < <(awk '$1=="nameserver" {print $2}' /etc/resolv.conf)
    fi

    if ((${#found[@]})); then
        printf '%s\n' "${found[@]}" | awk '!seen[$0]++' | paste -sd' ' -
    fi
}

detect_network() {
    local -a default_lines=() addresses=()
    local route addr_count mac carrier_count=0 p

    mapfile -t default_lines < <(ip -4 route show default 2>/dev/null | grep -E '(^| )dev ' || true)
    ((${#default_lines[@]} > 0)) || die "No IPv4 default route found. Use explicit network settings or fix networking first."

    if [[ -z "$IFACE" ]]; then
        local distinct_default_ifaces
        distinct_default_ifaces="$(printf '%s\n' "${default_lines[@]}" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | sort -u | wc -l)"
        if (( distinct_default_ifaces > 1 )) && (( FORCE_NETWORK == 0 )); then
            die "Multiple IPv4 default-route interfaces detected. Use --interface IFACE after verifying the intended remote path, or --force-network."
        fi
        route="${default_lines[0]}"
        IFACE="$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"$route")"
        [[ -n "$IFACE" ]] || die "Could not detect default-route interface."
    fi

    ip link show dev "$IFACE" >/dev/null 2>&1 || die "Interface not found: $IFACE"

    local nonstandard_rules
    nonstandard_rules="$(ip -4 rule show | awk '$1 != "0:" && $1 != "32766:" && $1 != "32767:" {n++} END {print n+0}')"
    if (( nonstandard_rules > 0 )) && (( FORCE_NETWORK == 0 )); then
        die "Non-standard IPv4 policy-routing rules are present. Debian Installer will not reproduce them automatically. Use --force-network only after verifying they are unnecessary during installation."
    fi

    if [[ "$INSTALLER_IFACE" == "auto" ]]; then
        for p in /sys/class/net/*; do
            [[ -e "$p/device" ]] || continue
            [[ "$(basename "$p")" == "lo" ]] && continue
            if [[ -r "$p/carrier" ]] && [[ "$(cat "$p/carrier" 2>/dev/null || echo 0)" == "1" ]]; then
                carrier_count=$((carrier_count + 1))
            fi
        done
        if (( carrier_count > 1 )) && (( FORCE_NETWORK == 0 )); then
            die "Multiple physical NICs have carrier. Re-run with --installer-interface IFACE (verify that d-i uses the same name), or --force-network."
        fi
    fi

    if [[ ! -e "/sys/class/net/$IFACE/device" ]] && (( FORCE_NETWORK == 0 )); then
        die "Default-route interface '$IFACE' is not a direct physical NIC (possible bridge/bond/VLAN). d-i will not reproduce that topology automatically. Use --force-network only after designing the installer network path."
    fi

    if [[ "$NETWORK_MODE" == "static" ]]; then
        if [[ -z "$ADDRESS_CIDR" ]]; then
            mapfile -t addresses < <(ip -4 -o addr show dev "$IFACE" scope global | awk '{print $4}')
            addr_count="${#addresses[@]}"
            (( addr_count == 1 )) || die "Expected exactly one global IPv4 on $IFACE, found $addr_count. Use --address explicitly."
            ADDRESS_CIDR="${addresses[0]}"
        fi
        [[ "$ADDRESS_CIDR" == */* ]] || die "--address must be IP/PREFIX, e.g. 203.0.113.50/24"

        if [[ -z "$GATEWAY" ]]; then
            GATEWAY="$(ip -4 route show default dev "$IFACE" | awk '/ via / {for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')"
            [[ -n "$GATEWAY" ]] || die "Could not detect an IPv4 gateway for $IFACE. Use --gateway explicitly."
        fi

        if [[ -z "$DNS_SERVERS" ]]; then
            DNS_SERVERS="$(collect_dns "$IFACE")"
            [[ -n "$DNS_SERVERS" ]] || die "Could not detect a non-loopback DNS server. Use --dns explicitly."
        fi
    fi

    mac="$(cat "/sys/class/net/$IFACE/address" 2>/dev/null || true)"

    printf '%s\n' \
        "Interface:           $IFACE" \
        "MAC:                 ${mac:-unknown}" \
        "Installer interface: $INSTALLER_IFACE" \
        "Network mode:        $NETWORK_MODE"

    if [[ "$NETWORK_MODE" == "static" ]]; then
        printf '%s\n' \
            "Address:             $ADDRESS_CIDR" \
            "Gateway:             $GATEWAY" \
            "DNS:                 $DNS_SERVERS"
    fi
}

check_grubenv_safety() {
    local abstraction fstype
    abstraction="$(grub-probe --target=abstraction /boot 2>/dev/null | paste -sd' ' - || true)"
    fstype="$(findmnt -rn -T /boot -o FSTYPE | head -n1)"

    log "GRUB /boot filesystem: ${fstype:-unknown}; abstraction: ${abstraction:-plain-disk}"

    if [[ -n "$abstraction" || "$fstype" == "btrfs" || "$fstype" == "zfs" ]]; then
        if (( FORCE_GRUBENV == 0 )); then
            die "GRUB may be unable to clear next_entry at boot on this /boot layout (filesystem=${fstype:-unknown}, abstraction=${abstraction:-none}). One-shot rollback is therefore not trustworthy. Re-run with --force-grubenv only if you accept that risk."
        fi
        warn "Proceeding despite a GRUB environment-block layout that may not support clearing next_entry at boot. A failed installer boot may repeat on the next power cycle."
    fi
}

check_environment() {
    need_root

    local cmd
    for cmd in bash awk sed grep cut tr head findmnt lsblk blkid ip curl cpio gzip openssl sha256sum df sync grub-probe; do
        need_cmd "$cmd"
    done

    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) die "This script currently supports amd64/x86_64 only. Detected: $(uname -m)" ;;
    esac

    command -v update-grub >/dev/null 2>&1 || \
    command -v grub2-mkconfig >/dev/null 2>&1 || \
    command -v grub-mkconfig >/dev/null 2>&1 || \
        die "No supported GRUB config generator found."

    command -v grub-reboot >/dev/null 2>&1 || \
    command -v grub2-reboot >/dev/null 2>&1 || \
        die "Neither grub-reboot nor grub2-reboot found."

    local sb boot_mb
    sb="$(secure_boot_state)"
    log "Firmware: $([[ -d /sys/firmware/efi ]] && echo UEFI || echo BIOS), Secure Boot: $sb"
    if [[ "$sb" == "enabled" && "$ALLOW_SECURE_BOOT" -ne 1 ]]; then
        die "Secure Boot is enabled. Refusing by default because the current shim/GRUB trust chain may reject the Debian installer kernel. Re-run with --allow-secure-boot only if you have verified that trust path."
    fi
    [[ "$sb" != "unknown" ]] || warn "Could not determine Secure Boot state. Verify it before rebooting."

    boot_mb="$(df -Pm /boot | awk 'NR==2 {print $4}')"
    [[ "$boot_mb" =~ ^[0-9]+$ ]] || die "Could not determine free space on /boot"
    (( boot_mb >= 80 )) || die "Need at least ~80 MiB free on /boot; found ${boot_mb} MiB."
    log "/boot free space: ${boot_mb} MiB"

    check_grubenv_safety
    detect_network
}

snapshot_system() {
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$WORK_DIR" "$BACKUP_DIR"

    uname -a > "$BACKUP_DIR/uname.txt"
    [[ -r /etc/os-release ]] && cp -a /etc/os-release "$BACKUP_DIR/os-release.txt"
    lsblk -e7 -o NAME,PATH,SIZE,TYPE,FSTYPE,FSVER,MOUNTPOINTS,UUID,PARTUUID > "$BACKUP_DIR/lsblk.txt"
    findmnt > "$BACKUP_DIR/findmnt.txt"
    blkid > "$BACKUP_DIR/blkid.txt" 2>&1 || true
    ip -br link > "$BACKUP_DIR/ip-link.txt"
    ip -br addr > "$BACKUP_DIR/ip-addr.txt"
    ip route show > "$BACKUP_DIR/ip-route.txt"
    ip rule show > "$BACKUP_DIR/ip-rule.txt"
    ip route show table all > "$BACKUP_DIR/ip-route-all.txt"
    [[ -r /etc/resolv.conf ]] && cp -a /etc/resolv.conf "$BACKUP_DIR/resolv.conf.txt"
    lspci -nnk > "$BACKUP_DIR/lspci-nnk.txt" 2>/dev/null || true

    {
        printf 'firmware=%s\n' "$([[ -d /sys/firmware/efi ]] && echo UEFI || echo BIOS)"
        printf 'secure_boot=%s\n' "$(secure_boot_state)"
        printf 'default_interface=%s\n' "$IFACE"
        printf 'default_interface_mac=%s\n' "$(cat "/sys/class/net/$IFACE/address" 2>/dev/null || true)"
    } > "$BACKUP_DIR/summary.txt"

    log "Saved current system/network/storage snapshot to $BACKUP_DIR"
}

create_preseed() {
    local password ip prefix netmask
    password="$(openssl rand -base64 30 | tr -d '\n' | tr '/+' '_-')"
    printf '%s\n' "$password" > "$PASSWORD_FILE"
    chmod 600 "$PASSWORD_FILE"

    {
        cat <<'PRESEED'
### Locale / keyboard
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us

PRESEED

        if [[ "$INSTALLER_IFACE" == "auto" ]]; then
            printf 'd-i netcfg/choose_interface select auto\n'
        else
            printf 'd-i netcfg/choose_interface select %s\n' "$INSTALLER_IFACE"
        fi

        if [[ "$NETWORK_MODE" == "dhcp" ]]; then
            cat <<'PRESEED'
d-i netcfg/dhcp_timeout string 60
d-i netcfg/get_hostname string debian13-install
d-i netcfg/get_domain string
PRESEED
        else
            ip="${ADDRESS_CIDR%/*}"
            prefix="${ADDRESS_CIDR#*/}"
            netmask="$(prefix_to_netmask "$prefix")"
            cat <<PRESEED
d-i netcfg/disable_autoconfig boolean true
d-i netcfg/get_ipaddress string $ip
d-i netcfg/get_netmask string $netmask
d-i netcfg/get_gateway string $GATEWAY
d-i netcfg/get_nameservers string $DNS_SERVERS
d-i netcfg/confirm_static boolean true
d-i netcfg/get_hostname string debian13-install
d-i netcfg/get_domain string
PRESEED
        fi

        cat <<PRESEED

### Start Debian Installer SSH network-console.
### The installer remains interactive; there is intentionally NO partition recipe.
d-i anna/choose_modules string network-console
d-i preseed/early_command string anna-install network-console
d-i network-console/password password $password
d-i network-console/password-again password $password

### Mirror
d-i mirror/country string manual
d-i mirror/http/hostname string deb.debian.org
d-i mirror/http/directory string /debian
d-i mirror/http/proxy string

### Prefer a minimal SSH-capable target when you reach software selection.
tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string openssh-server
PRESEED
    } > "$PRESEED_FILE"

    chmod 600 "$PRESEED_FILE"
    log "Created preseed: $PRESEED_FILE"
}

download_installer() {
    local tmp sums linux_rel initrd_rel
    tmp="$WORK_DIR/download"
    rm -rf "$tmp"
    mkdir -p "$tmp" "$BOOT_DIR"
    chmod 700 "$tmp" "$BOOT_DIR"

    sums="$tmp/SHA256SUMS"
    linux_rel="./${NETBOOT_REL}/linux"
    initrd_rel="./${NETBOOT_REL}/initrd.gz"

    log "Downloading Debian ${DEBIAN_SUITE} installer and checksums..."
    curl -fL --retry 3 --connect-timeout 15 "$BASE_URL/SHA256SUMS" -o "$sums"
    curl -fL --retry 3 --connect-timeout 15 "$NETBOOT_URL/linux" -o "$tmp/linux"
    curl -fL --retry 3 --connect-timeout 15 "$NETBOOT_URL/initrd.gz" -o "$tmp/initrd.orig.gz"

    local expected_linux expected_initrd actual
    expected_linux="$(awk -v p="$linux_rel" '$2==p {print $1; exit}' "$sums")"
    expected_initrd="$(awk -v p="$initrd_rel" '$2==p {print $1; exit}' "$sums")"
    [[ -n "$expected_linux" && -n "$expected_initrd" ]] || die "Could not find installer hashes in SHA256SUMS."

    actual="$(sha256sum "$tmp/linux" | awk '{print $1}')"
    [[ "$actual" == "$expected_linux" ]] || die "SHA256 mismatch for Debian installer linux. Mirror may be mid-sync; retry later."
    actual="$(sha256sum "$tmp/initrd.orig.gz" | awk '{print $1}')"
    [[ "$actual" == "$expected_initrd" ]] || die "SHA256 mismatch for Debian installer initrd.gz. Mirror may be mid-sync; retry later."

    log "Debian installer SHA256 checks passed."

    (
        cd "$WORK_DIR"
        printf 'preseed.cfg\n' | cpio --quiet -H newc -o | gzip -9c > "$tmp/preseed.cpio.gz"
    )
    cat "$tmp/initrd.orig.gz" "$tmp/preseed.cpio.gz" > "$tmp/initrd-remote.gz"

    install -m 600 "$tmp/linux" "$BOOT_DIR/linux"
    install -m 600 "$tmp/initrd-remote.gz" "$BOOT_DIR/initrd-remote.gz"

    sha256sum "$BOOT_DIR/linux" "$BOOT_DIR/initrd-remote.gz" > "$WORK_DIR/installer-local.sha256"
    log "Installed boot files under $BOOT_DIR"
}

detect_grub_cfg() {
    local p
    if [[ -d /sys/firmware/efi && -e /etc/grub2-efi.cfg ]]; then
        p="$(readlink -f /etc/grub2-efi.cfg)"
    elif [[ -e /etc/grub2.cfg ]]; then
        p="$(readlink -f /etc/grub2.cfg)"
    elif [[ -e /boot/grub/grub.cfg ]]; then
        p="/boot/grub/grub.cfg"
    elif [[ -e /boot/grub2/grub.cfg ]]; then
        p="/boot/grub2/grub.cfg"
    else
        die "Could not locate grub.cfg"
    fi
    [[ -f "$p" ]] || die "GRUB config does not exist: $p"
    printf '%s' "$p"
}

grub_commands() {
    local grub_cfg="$1"
    local linux_cmd="linux" initrd_cmd="initrd"

    if grep -Eq '^[[:space:]]*linuxefi[[:space:]]' "$grub_cfg"; then
        linux_cmd="linuxefi"
    elif grep -Eq '^[[:space:]]*linux16[[:space:]]' "$grub_cfg"; then
        linux_cmd="linux16"
    fi

    if grep -Eq '^[[:space:]]*initrdefi[[:space:]]' "$grub_cfg"; then
        initrd_cmd="initrdefi"
    elif grep -Eq '^[[:space:]]*initrd16[[:space:]]' "$grub_cfg"; then
        initrd_cmd="initrd16"
    fi

    printf '%s %s' "$linux_cmd" "$initrd_cmd"
}

ensure_40_custom() {
    local f="/etc/grub.d/40_custom"
    if [[ ! -e "$f" ]]; then
        cat > "$f" <<'CUSTOM'
#!/bin/sh
exec tail -n +3 $0
# Custom GRUB menu entries follow.
CUSTOM
        chmod 755 "$f"
    fi
    [[ -f "$f" ]] || die "$f is not a regular file"
}

remove_managed_grub_block() {
    local f="/etc/grub.d/40_custom" tmp
    [[ -f "$f" ]] || return 0
    tmp="$(mktemp)"
    awk -v begin="$MARK_BEGIN" -v end="$MARK_END" '
        $0 == begin {skip=1; next}
        $0 == end   {skip=0; next}
        !skip {print}
    ' "$f" > "$tmp"
    cat "$tmp" > "$f"
    rm -f "$tmp"
}

regenerate_grub() {
    local grub_cfg="$1"
    if command -v update-grub >/dev/null 2>&1; then
        update-grub
    elif command -v grub2-mkconfig >/dev/null 2>&1; then
        grub2-mkconfig -o "$grub_cfg"
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        grub-mkconfig -o "$grub_cfg"
    else
        die "No GRUB config generator found."
    fi
}

install_grub_entry() {
    local grub_cfg boot_uuid grub_path_prefix linux_cmd initrd_cmd commands backup_stamp
    grub_cfg="$(detect_grub_cfg)"
    boot_uuid="$(grub-probe --target=fs_uuid /boot 2>/dev/null)"
    [[ -n "$boot_uuid" ]] || die "grub-probe could not determine filesystem UUID for /boot"

    if findmnt -rn -M /boot >/dev/null 2>&1; then
        grub_path_prefix="/debian13-remote-install"
    else
        grub_path_prefix="/boot/debian13-remote-install"
    fi

    commands="$(grub_commands "$grub_cfg")"
    linux_cmd="${commands%% *}"
    initrd_cmd="${commands#* }"

    ensure_40_custom
    mkdir -p "$WORK_DIR/backups"
    backup_stamp="$(date +%Y%m%d-%H%M%S)"
    cp -a /etc/grub.d/40_custom "$WORK_DIR/backups/40_custom.$backup_stamp"

    remove_managed_grub_block

    cat >> /etc/grub.d/40_custom <<GRUBENTRY
$MARK_BEGIN
menuentry '$ENTRY_TITLE' --id '$ENTRY_ID' {
    search --no-floppy --fs-uuid --set=root $boot_uuid
    $linux_cmd $grub_path_prefix/linux auto=true priority=critical
    $initrd_cmd $grub_path_prefix/initrd-remote.gz
}
$MARK_END
GRUBENTRY

    regenerate_grub "$grub_cfg"

    grep -Fq -- "$ENTRY_TITLE" "$grub_cfg" || \
        die "Generated grub.cfg does not contain the Debian remote installer entry."

    if command -v grub-script-check >/dev/null 2>&1; then
        grub-script-check "$grub_cfg"
    elif command -v grub2-script-check >/dev/null 2>&1; then
        grub2-script-check "$grub_cfg"
    else
        warn "No grub-script-check/grub2-script-check found; syntax check skipped."
    fi

    log "GRUB entry installed and grub.cfg regenerated: $grub_cfg"
}

save_state() {
    mkdir -p "$WORK_DIR"
    {
        printf 'VERSION=%q\n' "$VERSION"
        printf 'NETWORK_MODE=%q\n' "$NETWORK_MODE"
        printf 'IFACE=%q\n' "$IFACE"
        printf 'INSTALLER_IFACE=%q\n' "$INSTALLER_IFACE"
        printf 'ADDRESS_CIDR=%q\n' "$ADDRESS_CIDR"
        printf 'GATEWAY=%q\n' "$GATEWAY"
        printf 'DNS_SERVERS=%q\n' "$DNS_SERVERS"
        printf 'GRUB_CFG=%q\n' "$(detect_grub_cfg)"
        printf 'PREPARED_AT=%q\n' "$(date -Is)"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

load_state() {
    [[ -r "$STATE_FILE" ]] || die "No prepared state found at $STATE_FILE. Run prepare first."
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}

grub_env_cmd() {
    if command -v grub-editenv >/dev/null 2>&1; then
        printf 'grub-editenv'
    elif command -v grub2-editenv >/dev/null 2>&1; then
        printf 'grub2-editenv'
    else
        die "No grub-editenv/grub2-editenv found."
    fi
}

grub_reboot_cmd() {
    if command -v grub-reboot >/dev/null 2>&1; then
        printf 'grub-reboot'
    elif command -v grub2-reboot >/dev/null 2>&1; then
        printf 'grub2-reboot'
    else
        die "No grub-reboot/grub2-reboot found."
    fi
}

cmd_check() {
    check_environment
    printf '\nCheck completed. No files or boot settings were changed.\n'
}

cmd_prepare() {
    check_environment

    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR"
    snapshot_system
    create_preseed
    download_installer
    install_grub_entry
    save_state

    printf '\n'
    printf '%s\n' '============================================================'
    printf '%s\n' 'PREPARED - nothing has been rebooted or partitioned.'
    printf '%s\n' '============================================================'
    printf 'Installer SSH user:     installer\n'
    printf 'Installer SSH password: %s\n' "$(cat "$PASSWORD_FILE")"
    if [[ "$NETWORK_MODE" == "static" ]]; then
        printf 'Expected installer IP:  %s\n' "${ADDRESS_CIDR%/*}"
    else
        printf 'Expected installer IP:  assigned by DHCP\n'
    fi
    printf '\nNext:\n'
    printf '  %s status\n' "$0"
    printf '  %s arm\n' "$0"
    printf '  reboot\n'
    printf '\nAfter reboot:\n'
    if [[ "$NETWORK_MODE" == "static" ]]; then
        printf '  ssh installer@%s\n' "${ADDRESS_CIDR%/*}"
    else
        printf '  ssh installer@<DHCP-address>\n'
    fi
    printf '\nDo NOT write partition changes until installer networking and lsblk are verified.\n'
}

cmd_status() {
    need_root
    local envcmd grub_cfg="" next="" sb
    sb="$(secure_boot_state)"

    printf 'Script version:          %s\n' "$VERSION"
    printf 'Firmware:                %s\n' "$([[ -d /sys/firmware/efi ]] && echo UEFI || echo BIOS)"
    printf 'Secure Boot:             %s\n' "$sb"
    printf 'Prepared state:          %s\n' "$([[ -r "$STATE_FILE" ]] && echo yes || echo no)"
    printf 'Boot kernel:             %s\n' "$([[ -r "$BOOT_DIR/linux" ]] && echo present || echo missing)"
    printf 'Boot initrd:             %s\n' "$([[ -r "$BOOT_DIR/initrd-remote.gz" ]] && echo present || echo missing)"

    if [[ -r "$STATE_FILE" ]]; then
        load_state
        printf 'Network mode:            %s\n' "$NETWORK_MODE"
        printf 'Current uplink:          %s\n' "$IFACE"
        printf 'Installer interface:     %s\n' "$INSTALLER_IFACE"
        if [[ "$NETWORK_MODE" == "static" ]]; then
            printf 'Installer address:       %s\n' "$ADDRESS_CIDR"
            printf 'Installer gateway:       %s\n' "$GATEWAY"
            printf 'Installer DNS:           %s\n' "$DNS_SERVERS"
        fi
        printf 'Installer password file: %s\n' "$PASSWORD_FILE"
        grub_cfg="${GRUB_CFG:-$(detect_grub_cfg)}"
        printf 'GRUB config:             %s\n' "$grub_cfg"
        if grep -Fq -- "$ENTRY_TITLE" "$grub_cfg" 2>/dev/null; then
            printf 'GRUB installer entry:    present\n'
        else
            printf 'GRUB installer entry:    MISSING\n'
        fi
    fi

    envcmd="$(grub_env_cmd 2>/dev/null || true)"
    if [[ -n "$envcmd" ]]; then
        next="$($envcmd - list 2>/dev/null | awk -F= '$1=="next_entry" {print $2}')"
        printf 'GRUB next_entry:         %s\n' "${next:-<not armed>}"
    fi
}

cmd_arm() {
    need_root
    load_state
    [[ -r "$BOOT_DIR/linux" && -r "$BOOT_DIR/initrd-remote.gz" ]] || die "Installer boot files missing. Run prepare again."
    [[ "$(secure_boot_state)" != "enabled" || "$ALLOW_SECURE_BOOT" -eq 1 ]] || die "Secure Boot is enabled. Refusing to arm without --allow-secure-boot."

    local grub_cfg reboot_cmd envcmd
    grub_cfg="${GRUB_CFG:-$(detect_grub_cfg)}"
    grep -Fq -- "$ENTRY_TITLE" "$grub_cfg" || die "Installer GRUB entry is missing from $grub_cfg"
    grep -Fq -- 'next_entry' "$grub_cfg" || die "This grub.cfg does not contain next_entry handling; grub-reboot rollback cannot be trusted."

    check_grubenv_safety

    reboot_cmd="$(grub_reboot_cmd)"
    "$reboot_cmd" "$ENTRY_ID"

    envcmd="$(grub_env_cmd)"
    if ! "$envcmd" - list 2>/dev/null | grep -Fq -- "next_entry=$ENTRY_ID"; then
        die "Failed to verify GRUB next_entry. Do NOT reboot."
    fi

    sync
    printf 'One-shot GRUB boot is ARMED: %s\n' "$ENTRY_ID"
    printf 'This command did NOT reboot the server.\n'
    printf '\nBefore rebooting, run:\n  %s status\n\n' "$0"
    printf 'To cancel:\n  %s disarm\n\n' "$0"
    printf 'When ready:\n  reboot\n'
}

cmd_disarm() {
    need_root
    local envcmd
    envcmd="$(grub_env_cmd)"
    "$envcmd" - unset next_entry 2>/dev/null || true
    if "$envcmd" - list 2>/dev/null | grep -q '^next_entry='; then
        die "Could not clear GRUB next_entry. Do NOT reboot."
    fi
    printf 'One-shot installer boot is disarmed. Normal GRUB default will be used.\n'
}

cmd_cleanup() {
    need_root
    if (( YES == 0 )); then
        printf 'This removes the managed GRUB entry and %s / %s.\n' "$WORK_DIR" "$BOOT_DIR"
        printf 'Type CLEANUP to continue: '
        local answer
        read -r answer
        [[ "$answer" == "CLEANUP" ]] || die "Cancelled."
    fi

    local envcmd grub_cfg
    envcmd="$(grub_env_cmd 2>/dev/null || true)"
    [[ -z "$envcmd" ]] || "$envcmd" - unset next_entry 2>/dev/null || true

    if [[ -f /etc/grub.d/40_custom ]]; then
        remove_managed_grub_block
        grub_cfg="$(detect_grub_cfg)"
        regenerate_grub "$grub_cfg"
    fi

    rm -rf "$BOOT_DIR" "$WORK_DIR"
    printf 'Removed Debian remote-installer bootstrap files and managed GRUB entry.\n'
}

main() {
    local cmd="${1:-}"
    [[ -n "$cmd" ]] || { usage; exit 2; }
    shift || true

    case "$cmd" in
        check)
            parse_options "$@"
            cmd_check ;;
        prepare)
            parse_options "$@"
            cmd_prepare ;;
        status)
            (($# == 0)) || die "status takes no options"
            cmd_status ;;
        arm)
            parse_options "$@"
            cmd_arm ;;
        disarm)
            (($# == 0)) || die "disarm takes no options"
            cmd_disarm ;;
        cleanup)
            parse_options "$@"
            cmd_cleanup ;;
        help|-h|--help)
            usage ;;
        *)
            usage
            die "Unknown command: $cmd" ;;
    esac
}

main "$@" 
