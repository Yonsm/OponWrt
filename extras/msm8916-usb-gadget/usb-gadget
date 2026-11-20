#!/bin/sh
# Universal USB Gadget Manager for OpenWrt
# Compatible with ash/busybox sh

set -e

# Load UCI library
. /lib/functions.sh

# ============================================================================
# Configuration
# ============================================================================

CFG_ENABLED=""
CFG_GADGET_NAME=""
CFG_GADGET_PATH=""
CFG_CONFIG_PATH=""
CFG_FUNCTIONS_PATH=""

CFG_VENDOR_ID=""
CFG_PRODUCT_ID=""
CFG_DEVICE_VERSION=""
CFG_MANUFACTURER=""
CFG_PRODUCT=""
CFG_UDC_DEVICE=""

CFG_RNDIS=""
CFG_ECM=""
CFG_NCM=""
CFG_ACM=""
CFG_UMS=""

CFG_ACM_SHELL=""

CFG_UMS_IMAGE=""
CFG_UMS_SIZE=""
CFG_UMS_READONLY=""

# Where usb-gadget-probe records the transport it picked for the host that is
# attached right now.  Runtime state, so it does not survive a reboot.
NETMODE_OVERRIDE="/var/run/usb-gadget/net_mode"

load_config() {
    config_load usbgadget
    
    # Global enable/disable
    config_get_bool CFG_ENABLED usb enabled 1
    
    # Gadget name
    config_get CFG_GADGET_NAME usb gadget_name "g1"
    
    # Paths
    CFG_GADGET_PATH="/sys/kernel/config/usb_gadget/${CFG_GADGET_NAME}"
    CFG_CONFIG_PATH="${CFG_GADGET_PATH}/configs/c.1"
    CFG_FUNCTIONS_PATH="${CFG_GADGET_PATH}/functions"
    
    # USB Device IDs
    config_get CFG_VENDOR_ID usb vendor_id "0x1d6b"
    config_get CFG_PRODUCT_ID usb product_id "0x0104"
    config_get CFG_DEVICE_VERSION usb device_version "0x0100"
    config_get CFG_MANUFACTURER usb manufacturer "OpenWrt"
    config_get CFG_PRODUCT usb product "USB Gadget"
    config_get CFG_UDC_DEVICE usb udc_device ""
    
    # Functions (boolean)
    config_get_bool CFG_RNDIS rndis enabled 0
    config_get_bool CFG_ECM ecm enabled 0
    config_get_bool CFG_NCM ncm enabled 0
    config_get_bool CFG_ACM acm enabled 0
    config_get_bool CFG_UMS ums enabled 0
    
    # ACM options
    config_get_bool CFG_ACM_SHELL acm shell 1
    
    # UMS options
    config_get CFG_UMS_IMAGE ums image_path "/var/lib/usb-gadget/storage.img"
    config_get CFG_UMS_SIZE ums image_size "512M"
    config_get_bool CFG_UMS_READONLY ums readonly 0

    # Which ethernet function to expose.  Unset means the per-function
    # booleans stand, which is what a unit that predates this option gets --
    # so an upgrade never changes the transport under a user.
    #
    #   auto   NCM, and RNDIS only if the host does not bind NCM (see the
    #          probe); NCM is the better transport everywhere it is supported
    #   ncm    NCM only
    #   rndis  RNDIS only -- Windows before 11, and Android hosts
    #   both   both at once: two adapters on the same subnet on any host that
    #          binds both, kept as an escape hatch, not a default
    config_get CFG_NET_MODE usb net_mode ""

    case "$CFG_NET_MODE" in
        "")
            ;;
        auto|ncm)
            CFG_NCM=1
            CFG_RNDIS=0
            ;;
        rndis)
            CFG_NCM=0
            CFG_RNDIS=1
            ;;
        both)
            CFG_NCM=1
            CFG_RNDIS=1
            ;;
        *)
            log "usbgadget.usb.net_mode '$CFG_NET_MODE' is not auto, ncm, rndis or both; keeping the per-function settings"
            CFG_NET_MODE=""
            ;;
    esac

    # A decision made by usb-gadget-probe for the host attached right now.
    # Only consulted in auto mode: an operator who pinned ncm or rndis must
    # never be overridden by a decision left behind for a different host.
    CFG_NETMODE_DECIDED=""
    if [ "$CFG_NET_MODE" = "auto" ] && [ -r "$NETMODE_OVERRIDE" ]; then
        CFG_NETMODE_DECIDED="$(cat "$NETMODE_OVERRIDE" 2>/dev/null)"
        case "$CFG_NETMODE_DECIDED" in
            ncm)
                CFG_NCM=1
                CFG_RNDIS=0
                ;;
            rndis)
                CFG_NCM=0
                CFG_RNDIS=1
                ;;
            *)
                CFG_NETMODE_DECIDED=""
                ;;
        esac
    fi
}

# ============================================================================
# Logging
# ============================================================================

log() {
    logger -t usb-gadget "$*"
    echo "[$(date '+%H:%M:%S')] $*" >&2
}

error() {
    log "ERROR: $*"
    exit 1
}

# ============================================================================
# Utilities
# ============================================================================

# Stable identity for this unit.  The host keys the device -- and every MAC
# derived from this -- on the serial, so a value that changes between boots
# makes Windows treat each plug as new hardware: the adapter walks up
# Ethernet 3 -> 4 -> 5 and the "set up a network" prompt returns every time.
# The old fallback was "$(date +%s)-$$", which is exactly that failure.
#
# Order: a machine-id the image or the user provided, then the eMMC CID (unique
# per part, survives any filesystem change), then one generated once and kept.
get_serial_number() {
    local id=""

    if [ -s /etc/machine-id ]; then
        id="$(cat /etc/machine-id 2>/dev/null)"
    fi

    if [ -z "$id" ] && [ -r /sys/block/mmcblk0/device/cid ]; then
        id="$(cat /sys/block/mmcblk0/device/cid 2>/dev/null)"
    fi

    if [ -z "$id" ]; then
        if [ ! -s /etc/machine-id ]; then
            cat /proc/sys/kernel/random/uuid > /etc/machine-id 2>/dev/null || true
        fi
        id="$(cat /etc/machine-id 2>/dev/null)"
    fi

    # Nothing persistent is available (no machine-id, no eMMC CID, /etc not
    # writable).  A per-boot value is wrong but a shared one is worse: two
    # units on the same desk must never present the same serial and MACs.
    [ -n "$id" ] || id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$$-$(date +%s)")"

    printf '%s' "$id" | sha256sum | cut -d' ' -f1 | cut -c1-16
}

generate_mac() {
    local prefix="$1"
    local serial="$(get_serial_number)"
    local hash="$(echo "${serial}${prefix}" | md5sum | cut -c1-12)"
    
    # Extract bytes
    local b1="$(echo "$hash" | cut -c1-2)"
    local b2="$(echo "$hash" | cut -c3-4)"
    local b3="$(echo "$hash" | cut -c5-6)"
    local b4="$(echo "$hash" | cut -c7-8)"
    local b5="$(echo "$hash" | cut -c9-10)"
    local b6="$(echo "$hash" | cut -c11-12)"
    
    # Set locally administered, unicast
    b1="$(printf '%02x' $((0x${b1} & 0xfe | 0x02)))"
    
    echo "${b1}:${b2}:${b3}:${b4}:${b5}:${b6}"
}

find_udc() {
    # Return configured UDC if set
    if [ -n "$CFG_UDC_DEVICE" ]; then
        echo "$CFG_UDC_DEVICE"
        return
    fi
    
    # Auto-detect UDC - works on ALL hardware
    local udc="$(ls /sys/class/udc/ 2>/dev/null | head -1)"
    
    if [ -z "$udc" ]; then
        error "No UDC device found. Is USB gadget support enabled?"
    fi
    
    echo "$udc"
}

sysfs_write() {
    local path="$1"
    local value="$2"
    echo "$value" > "$path" || error "Failed to write '$value' to $path"
}

# ============================================================================
# USB Functions Setup
# ============================================================================

setup_rndis() {
    log "Enabling RNDIS"
    local func="${CFG_FUNCTIONS_PATH}/rndis.usb0"
    
    mkdir -p "$func"
    sysfs_write "${func}/host_addr" "$(generate_mac rndis-host)"
    sysfs_write "${func}/dev_addr" "$(generate_mac rndis-dev)"
    ln -sf "$func" "${CFG_CONFIG_PATH}/"
    
    # Windows compatibility
    sysfs_write "${CFG_GADGET_PATH}/os_desc/use" "1"
    sysfs_write "${CFG_GADGET_PATH}/os_desc/b_vendor_code" "0xcd"
    sysfs_write "${CFG_GADGET_PATH}/os_desc/qw_sign" "MSFT100"
    sysfs_write "${func}/os_desc/interface.rndis/compatible_id" "RNDIS"
    sysfs_write "${func}/os_desc/interface.rndis/sub_compatible_id" "5162001"

    # Interface association: class EF, subclass 04, protocol 01 -- Microsoft's
    # RNDIS IAD.  Windows then matches USB\Class_ef&SubClass_04&Prot_01 with
    # the inbox rndiscmp.inf and needs no WCID negotiation at all (measured on
    # a Windows 10 LTSC host, #102).
    #
    # These three are parsed as at most TWO hex digits: "0xef" stores 0 and
    # "239" stores 0x23, so the association silently becomes 00/00/00 and the
    # host stops claiming the interface.  Only these spellings are correct.
    sysfs_write "${func}/class"    "ef"
    sysfs_write "${func}/subclass" "04"
    sysfs_write "${func}/protocol" "01"

    ln -sf "${CFG_CONFIG_PATH}" "${CFG_GADGET_PATH}/os_desc/"
    
    echo "+RNDIS"
}

setup_ecm() {
    log "Enabling ECM"
    local func="${CFG_FUNCTIONS_PATH}/ecm.usb0"
    
    mkdir -p "$func"
    sysfs_write "${func}/host_addr" "$(generate_mac ecm-host)"
    sysfs_write "${func}/dev_addr" "$(generate_mac ecm-dev)"
    ln -sf "$func" "${CFG_CONFIG_PATH}/"
    
    echo "+ECM"
}

setup_ncm() {
    log "Enabling NCM"
    local func="${CFG_FUNCTIONS_PATH}/ncm.usb0"
    
    mkdir -p "$func"
    sysfs_write "${func}/host_addr" "$(generate_mac ncm-host)"
    sysfs_write "${func}/dev_addr" "$(generate_mac ncm-dev)"
    ln -sf "$func" "${CFG_CONFIG_PATH}/"
    
    echo "+NCM"
}

setup_acm() {
    log "Enabling ACM"
    local func="${CFG_FUNCTIONS_PATH}/acm.GS0"
    
    mkdir -p "$func"
    ln -sf "$func" "${CFG_CONFIG_PATH}/"
    
    # Manage shell in inittab
    if [ "$CFG_ACM_SHELL" = "1" ]; then
        log "Enabling serial shell on ttyGS0"
        sed -i '/ttyGS0/d' /etc/inittab
        echo "ttyGS0::askfirst:/usr/libexec/login.sh" >> /etc/inittab
    else
        log "ACM in raw TTY mode (removing shell from inittab)"
        sed -i '/ttyGS0/d' /etc/inittab
    fi
    
    kill -HUP 1 2>/dev/null || true
    
    echo "+ACM"
}

setup_ums() {
    local image="$CFG_UMS_IMAGE"
    
    # Create image if doesn't exist
    if [ ! -f "$image" ]; then
        log "Creating storage image: $image ($CFG_UMS_SIZE)"
        mkdir -p "$(dirname "$image")"
        truncate -s "$CFG_UMS_SIZE" "$image" || \
            dd if=/dev/zero of="$image" bs=1M count="${CFG_UMS_SIZE%M}"
    fi
    
    log "Enabling UMS"
    local func="${CFG_FUNCTIONS_PATH}/mass_storage.0"
    
    mkdir -p "$func"
    sysfs_write "${func}/lun.0/ro" "$CFG_UMS_READONLY"
    sysfs_write "${func}/lun.0/file" "$image"
    ln -sf "$func" "${CFG_CONFIG_PATH}/"
    
    echo "+UMS"
}

# ============================================================================
# Network Configuration
# ============================================================================

bring_up_iface() {
    local ifname_file="$1"
    [ -f "$ifname_file" ] || return 0
    local iface="$(cat "$ifname_file")"
    [ -n "$iface" ] || return 0
    ip link set "$iface" up 2>/dev/null || ifconfig "$iface" up 2>/dev/null || true
    return 0
}

add_to_bridge() {
    local ifname_file="$1"
    
    [ -f "$ifname_file" ] || return 0
    
    local iface="$(cat "$ifname_file")"
    [ -n "$iface" ] || return 0
    log "Adding $iface to bridge"
    
    # Ensure interface is administrative UP so carrier is signalled to host
    ip link set "$iface" up 2>/dev/null || ifconfig "$iface" up 2>/dev/null || true

    local dev_sec=""
    for s in $(uci -q show network | grep -E '\.name=.br-lan.' | cut -d. -f2); do
        dev_sec="$s"
        break
    done
    if [ -z "$dev_sec" ]; then dev_sec="@device[0]"; fi

    # Add the interface to bridge
    uci -q del_list "network.${dev_sec}.ports=$iface" 2>/dev/null || true
    uci add_list "network.${dev_sec}.ports=$iface"

    # Immediately attach to kernel bridge
    ip link set "$iface" master br-lan 2>/dev/null || brctl addif br-lan "$iface" 2>/dev/null || true
    return 0
}

setup_network() {
    sleep 1

    # Plain `if`s, not `cond && cmd`: the script runs under `set -e`, and a
    # trailing `[ ... ] && cmd` whose test fails makes the whole script exit
    # with 1.  That is every RNDIS build, where CFG_NCM is 0 -- the rebuild
    # worked but `usb-gadget restart` reported failure.
    if [ "$CFG_RNDIS" = "1" ]; then add_to_bridge "${CFG_FUNCTIONS_PATH}/rndis.usb0/ifname"; fi
    if [ "$CFG_ECM" = "1" ]; then add_to_bridge "${CFG_FUNCTIONS_PATH}/ecm.usb0/ifname"; fi
    if [ "$CFG_NCM" = "1" ]; then add_to_bridge "${CFG_FUNCTIONS_PATH}/ncm.usb0/ifname"; fi
    
    uci commit network
    /etc/init.d/network reload
    /etc/init.d/dnsmasq restart 2>/dev/null || true
    /etc/init.d/odhcpd restart 2>/dev/null || true
    /etc/init.d/firewall reload 2>/dev/null || true

    # Post-reload bringup check
    if [ "$CFG_RNDIS" = "1" ]; then bring_up_iface "${CFG_FUNCTIONS_PATH}/rndis.usb0/ifname"; fi
    if [ "$CFG_ECM" = "1" ]; then bring_up_iface "${CFG_FUNCTIONS_PATH}/ecm.usb0/ifname"; fi
    if [ "$CFG_NCM" = "1" ]; then bring_up_iface "${CFG_FUNCTIONS_PATH}/ncm.usb0/ifname"; fi
    return 0
}

# ============================================================================
# Main Gadget Management
# ============================================================================

setup_gadget() {
    # Load configuration
    load_config
    
    # Check if gadget is enabled
    if [ "$CFG_ENABLED" != "1" ]; then
        log "USB Gadget is disabled in config (usb.enabled=0)"
        log "USB port available for host mode"
        return 0
    fi
    
    log "Setting up USB gadget"
    log "Gadget name: $CFG_GADGET_NAME"
    log "Gadget path: $CFG_GADGET_PATH"
    
    # Prepare system
    if ! lsmod | grep -q "^libcomposite "; then
        modprobe libcomposite 2>/dev/null || true
    fi
    
    if ! mountpoint -q /sys/kernel/config; then
        log "Mounting configfs"
        mount -t configfs none /sys/kernel/config
    fi
    
    # Create gadget directory
    mkdir -p "$CFG_GADGET_PATH" || error "Failed to create gadget directory"
    cd "$CFG_GADGET_PATH" || error "Cannot change directory"
    
    # Device descriptors
    sysfs_write idVendor "$CFG_VENDOR_ID"
    sysfs_write idProduct "$CFG_PRODUCT_ID"
    sysfs_write bcdDevice "$CFG_DEVICE_VERSION"
    
    # Composite device class
    sysfs_write bDeviceClass "0xEF"
    sysfs_write bDeviceSubClass "0x02"
    sysfs_write bDeviceProtocol "0x01"
    
    # Strings (USB descriptors)
    mkdir -p strings/0x409
    sysfs_write strings/0x409/serialnumber "$(get_serial_number)"
    sysfs_write strings/0x409/manufacturer "$CFG_MANUFACTURER"
    sysfs_write strings/0x409/product "$CFG_PRODUCT"
    
    # Configuration
    mkdir -p "${CFG_CONFIG_PATH}/strings/0x409"
    
    local config_string=""
    local has_wakeup=0
    
    # Setup enabled functions in order
    # RNDIS must be first for Windows compatibility
    if [ "$CFG_RNDIS" = "1" ]; then
        config_string="${config_string}$(setup_rndis)"
        has_wakeup=1
    fi
    
    if [ "$CFG_ACM" = "1" ]; then
        config_string="${config_string}$(setup_acm)"
    fi
    
    if [ "$CFG_ECM" = "1" ] && [ "$CFG_NCM" != "1" ]; then
        config_string="${config_string}$(setup_ecm)"
        has_wakeup=1
    fi
    
    if [ "$CFG_NCM" = "1" ]; then
        config_string="${config_string}$(setup_ncm)"
        has_wakeup=1
    fi
    
    if [ "$CFG_UMS" = "1" ]; then
        config_string="${config_string}$(setup_ums)"
    fi
    
    # Check if any function was enabled
    if [ -z "$config_string" ]; then
        log "WARNING: No USB functions enabled"
        log "Enable at least one function (rndis, ecm, ncm, acm, or ums)"
        cd /sys/kernel/config/usb_gadget
        rmdir "$CFG_GADGET_NAME" 2>/dev/null || true
        return 1
    fi
    
    # Configuration attributes
    if [ "$has_wakeup" = "1" ]; then
        sysfs_write "${CFG_CONFIG_PATH}/bmAttributes" "0xe0"
    else
        sysfs_write "${CFG_CONFIG_PATH}/bmAttributes" "0xc0"
    fi
    
    sysfs_write "${CFG_CONFIG_PATH}/MaxPower" "250"
    
    # Set configuration string (remove leading +)
    config_string="$(echo "$config_string" | sed 's/^+//')"
    sysfs_write "${CFG_CONFIG_PATH}/strings/0x409/configuration" "$config_string"
    
    # Find and enable UDC
    local udc="$(find_udc)"
    log "Enabling UDC: $udc"
    sysfs_write UDC "$udc"
    
    # Configure network
    setup_network
    
    log "USB Gadget setup complete"
}

teardown_gadget() {
    log "Tearing down USB gadget"
    
    # Load config to get paths
    load_config
    
    if [ ! -d "$CFG_GADGET_PATH" ]; then
        log "Gadget not found, nothing to tear down"
        return
    fi
    
    cd "$CFG_GADGET_PATH" || return
    
    # Disable gadget
    echo "" > UDC 2>/dev/null || true
    
    # Remove from network bridge
    for ifname in functions/*/ifname; do
        if [ -f "$ifname" ]; then
            local iface="$(cat "$ifname")"
            [ -n "$iface" ] || continue
            for dev_sec in $(uci -q show network | grep -E '\.name=.br-lan.' | cut -d. -f2) "@device[0]"; do
                uci -q del_list "network.${dev_sec}.ports=$iface" 2>/dev/null || true
            done
        fi
    done
    uci commit network
    /etc/init.d/network reload
    
    # Remove configuration links
    rm -f configs/c.1/* 2>/dev/null || true
    rm -f os_desc/c.1 2>/dev/null || true
    rmdir configs/c.1/strings/0x409 2>/dev/null || true
    rmdir configs/c.1 2>/dev/null || true
    
    # Remove function directories
    for func in functions/*; do
        [ -d "$func" ] && rmdir "$func" 2>/dev/null || true
    done
    
    # Remove strings
    rmdir strings/0x409 2>/dev/null || true
    
    # Remove gadget
    cd /sys/kernel/config/usb_gadget
    rmdir "$CFG_GADGET_NAME" 2>/dev/null || true
    
    # Clean shell from inittab
    sed -i '/ttyGS0/d' /etc/inittab
    kill -HUP 1 2>/dev/null || true
    
    log "Teardown complete"
    log "USB port available for host mode"
}

status() {
    load_config

    echo "Network mode: ${CFG_NET_MODE:-legacy} (ncm=$CFG_NCM rndis=$CFG_RNDIS ecm=$CFG_ECM)"
    if [ -n "$CFG_NETMODE_DECIDED" ]; then
        echo "Probe decision: $CFG_NETMODE_DECIDED (for the host attached now)"
    fi
    echo "Serial: $(get_serial_number)"
    
    # Check if globally disabled
    if [ "$CFG_ENABLED" != "1" ]; then
        echo "USB Gadget: Disabled in configuration"
        echo "Status: Inactive (host mode available)"
        echo ""
        echo "To enable: uci set usbgadget.usb.enabled='1' && uci commit"
        return 1
    fi
    
    if [ -d "$CFG_GADGET_PATH" ] && [ -s "${CFG_GADGET_PATH}/UDC" ]; then
        echo "USB Gadget: $CFG_GADGET_NAME"
        echo "Status: Active (device mode)"
        echo "UDC: $(cat "${CFG_GADGET_PATH}/UDC")"
        echo ""
        echo "Enabled functions:"
        ls -1 "$CFG_CONFIG_PATH" 2>/dev/null | grep -v strings | sed 's/^/  - /'
        
        # Show ACM status
        if [ "$CFG_ACM" = "1" ]; then
            echo ""
            echo "Serial console:"
            if [ -c /dev/ttyGS0 ]; then
                if [ "$CFG_ACM_SHELL" = "1" ]; then
                    echo "  /dev/ttyGS0 - Available (with shell)"
                else
                    echo "  /dev/ttyGS0 - Available (raw TTY)"
                fi
            else
                echo "  /dev/ttyGS0 - Not found"
            fi
        fi
        
        # Show network interfaces
        echo ""
        echo "Network interfaces:"
        for ifname in "${CFG_FUNCTIONS_PATH}"/*/ifname; do
            if [ -f "$ifname" ]; then
                local iface="$(cat "$ifname")"
                local state="$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo unknown)"
                echo "  - $iface ($state)"
            fi
        done
        
        return 0
    else
        echo "USB Gadget: $CFG_GADGET_NAME"
        echo "Status: Inactive"
        echo ""
        echo "Start with: /etc/init.d/usb-gadget start"
        return 1
    fi
}

# ============================================================================
# Main Entry Point
# ============================================================================

case "${1:-}" in
    start)
        teardown_gadget
        setup_gadget
        ;;
    stop)
        teardown_gadget
        ;;
    restart)
        teardown_gadget
        setup_gadget
        ;;
    status)
        status
        ;;
    -h|--help)
        cat <<'USAGE'
Usage: usb-gadget {start|stop|restart|status} | -h|--help

Build, tear down or inspect the USB gadget described by /etc/config/usbgadget.
All configuration lives in uci; this script only applies it.

Commands:
  start     (Re)build the gadget from the current uci config
  stop      Tear the gadget down
  restart   Tear down, then build again
  status    Show the configured functions and the live UDC state

Options:
  -h, --help   Show this help and exit

Configuration:
  uci show usbgadget
  uci set usbgadget.<section>.<option>=<value> && uci commit usbgadget

Service:  /etc/init.d/usb-gadget {start|stop|restart|status}
USAGE
        exit 0
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}  (see --help)" >&2
        exit 1
        ;;
esac
