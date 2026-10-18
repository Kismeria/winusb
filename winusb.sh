#!/usr/bin/env bash
# winusb - write a Windows ISO to a USB stick from Linux (UEFI boot)
# usage: curl -fsSL https://raw.githubusercontent.com/Kismeria/winusb/main/winusb.sh | sudo bash
#    or: sudo ./winusb.sh [path/to/windows.iso]
set -euo pipefail

# when piped from curl stdin is the script itself, read prompts from the terminal
exec 3</dev/tty || { echo "no terminal available"; exit 1; }
ask() { local a; read -r -u 3 -p "$1" a; echo "$a"; }

if [[ $EUID -ne 0 ]]; then
    if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        exec sudo bash "${BASH_SOURCE[0]}" "$@"
    fi
    echo "run with sudo"; exit 1
fi

ISO="${1:-}"
MNT_ISO=$(mktemp -d /tmp/winusb-iso.XXXX)
MNT_USB=$(mktemp -d /tmp/winusb-usb.XXXX)
TMPD=""

cleanup() {
    set +e
    [[ -n "$TMPD" ]] && rm -rf "$TMPD"
    sync
    mountpoint -q "$MNT_USB" && umount "$MNT_USB"
    mountpoint -q "$MNT_ISO" && umount "$MNT_ISO"
    rmdir "$MNT_USB" "$MNT_ISO" 2>/dev/null
}
trap cleanup EXIT

install_deps() {
    local need=() c
    for c in parted mkfs.vfat rsync wimlib-imagex wipefs lsblk; do
        command -v "$c" >/dev/null || need+=("$c")
    done
    [[ ${#need[@]} -eq 0 ]] && return
    echo "missing: ${need[*]}"
    if   command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y parted dosfstools rsync wimtools util-linux
    elif command -v pacman  >/dev/null; then pacman -S --needed --noconfirm parted dosfstools rsync wimlib util-linux
    elif command -v dnf     >/dev/null; then dnf install -y parted dosfstools rsync wimlib-utils util-linux
    elif command -v zypper  >/dev/null; then zypper install -y parted dosfstools rsync wimlib util-linux
    else echo "install manually: parted dosfstools rsync wimlib util-linux"; exit 1
    fi
}

pick_iso() {
    [[ -n "$ISO" ]] && return
    local home="${SUDO_USER:+/home/$SUDO_USER}"
    local found=() f
    while IFS= read -r f; do found+=("$f"); done < <(
        find "${home:-$HOME}/Downloads" "${home:-$HOME}" "$PWD" -maxdepth 2 -type f -iname '*.iso' 2>/dev/null | sort -u
    )
    if [[ ${#found[@]} -eq 0 ]]; then
        ISO=$(ask "iso path: ")
    else
        echo "iso:"
        local i
        for i in "${!found[@]}"; do printf '  %d) %s (%s)\n' "$((i+1))" "${found[$i]}" "$(du -h "${found[$i]}" | cut -f1)"; done
        echo "  0) other path"
        local n; n=$(ask "pick: ")
        if [[ "$n" =~ ^[1-9][0-9]*$ ]] && (( n <= ${#found[@]} )); then ISO="${found[$((n-1))]}"
        else ISO=$(ask "iso path: ")
        fi
    fi
    [[ -f "$ISO" ]] || { echo "no such file: $ISO"; exit 1; }
}

pick_disk() {
    local disks=() line
    while IFS= read -r line; do disks+=("$line"); done < <(
        lsblk -dnpo NAME,SIZE,MODEL,TRAN,RM,TYPE | awk '$NF=="disk" && ($(NF-1)==1 || $(NF-2)=="usb")'
    )
    if [[ ${#disks[@]} -eq 0 ]]; then echo "no usb drives found"; exit 1; fi
    echo "drives:"
    local i
    for i in "${!disks[@]}"; do echo "  $((i+1))) $(lsblk -dnpo NAME,SIZE,MODEL "${disks[$i]%% *}")"; done
    local n; n=$(ask "pick: ")
    [[ "$n" =~ ^[1-9][0-9]*$ ]] && (( n <= ${#disks[@]} )) || { echo "bad choice"; exit 1; }
    DISK=${disks[$((n-1))]%% *}
}

install_deps
pick_iso
pick_disk

echo
echo "iso:   $ISO"
echo "drive: $DISK  (ALL DATA WILL BE ERASED)"
lsblk -po NAME,SIZE,FSTYPE,LABEL "$DISK"
[[ "$(ask "type the drive name ($DISK) to continue: ")" == "$DISK" ]] || { echo "cancelled"; exit 1; }

echo "[1/5] wiping"
for p in $(lsblk -lnpo NAME "$DISK" | tail -n +2); do umount "$p" 2>/dev/null || true; done
wipefs -a "$DISK" >/dev/null
parted -s "$DISK" mklabel gpt mkpart WINUSB fat32 1MiB 100%
partprobe "$DISK"; udevadm settle
if [[ "$DISK" =~ [0-9]$ ]]; then PART="${DISK}p1"; else PART="${DISK}1"; fi

echo "[2/5] formatting fat32"
mkfs.vfat -F32 -n WINUSB "$PART" >/dev/null

echo "[3/5] mounting"
mount -o loop,ro "$ISO" "$MNT_ISO"
mount "$PART" "$MNT_USB"

echo "[4/5] copying"
rsync -rh --info=progress2 --no-perms --no-owner --no-group \
    --exclude='sources/install.wim' --exclude='sources/install.esd' "$MNT_ISO"/ "$MNT_USB"/
for f in install.wim install.esd; do
    SRC="$MNT_ISO/sources/$f"
    [[ -f "$SRC" ]] || continue
    if (( $(stat -c %s "$SRC") <= 4294967295 )); then
        cp "$SRC" "$MNT_USB/sources/$f"
        continue
    fi
    if [[ "$f" == install.esd ]]; then
        # fat32 cannot hold it and wimlib cannot split esd, so convert to a plain wim first
        echo "$f over 4gb, converting to wim (slow)"
        need=$(( $(stat -c %s "$SRC") * 2 ))
        avail=$(df --output=avail -B1 /var/tmp | tail -1)
        (( avail >= need )) || { echo "need $((need / 1073741824))gb free in /var/tmp"; exit 1; }
        TMPD=$(mktemp -d /var/tmp/winusb-wim.XXXX)
        wimlib-imagex export "$SRC" all "$TMPD/install.wim" --compress=LZX
        SRC="$TMPD/install.wim"
    fi
    echo "splitting into 3800mb parts"
    wimlib-imagex split "$SRC" "$MNT_USB/sources/install.swm" 3800
done

echo "[5/5] flushing"
sync
echo "done. boot the stick in uefi mode"
