#!/bin/sh
. /lib/netifd/mac80211.sh

append DRIVERS "mac80211"

lookup_phy() {
	[ -n "$phy" ] && {
		[ -d /sys/class/ieee80211/$phy ] && return
	}

	local devpath
	config_get devpath "$device" path
	[ -n "$devpath" ] && {
		phy="$(mac80211_path_to_phy "$devpath")"
		[ -n "$phy" ] && return
	}

	local macaddr="$(config_get "$device" macaddr | tr 'A-Z' 'a-z')"
	[ -n "$macaddr" ] && {
		for _phy in /sys/class/ieee80211/*; do
			[ -e "$_phy" ] || continue

			[ "$macaddr" = "$(cat ${_phy}/macaddress)" ] || continue
			phy="${_phy##*/}"
			return
		done
	}
	phy=
	return
}

find_mac80211_phy() {
	local device="$1"

	config_get phy "$device" phy
	lookup_phy
	[ -n "$phy" -a -d "/sys/class/ieee80211/$phy" ] || {
		echo "PHY for wifi device $1 not found"
		return 1
	}
	config_set "$device" phy "$phy"

	config_get macaddr "$device" macaddr
	[ -z "$macaddr" ] && {
		config_set "$device" macaddr "$(cat /sys/class/ieee80211/${phy}/macaddress)"
	}

	return 0
}

check_mac80211_device() {
	config_get phy "$1" phy
	[ -z "$phy" ] && {
		find_mac80211_phy "$1" >/dev/null || return 0
		config_get phy "$1" phy
	}
	[ "$phy" = "$dev" ] && found=1
}


__get_band_defaults() {
	local phy="$1"

	( iw phy "$phy" info; echo ) | awk '
BEGIN {
        bands = ""
}

($1 == "Band" || $1 == "") && band {
        if (channel) {
		mode="NOHT"
		if (ht) mode="HT20"
		if (vht && band != "1:") mode="VHT80"
		if (he) mode="HE80"
		if (he && band == "1:") mode="HE20"
                sub("\\[", "", channel)
                sub("\\]", "", channel)
                bands = bands band channel ":" mode " "
        }
        band=""
}

$1 == "Band" {
        band = $2
        channel = ""
	vht = ""
	ht = ""
	he = ""
}

$0 ~ "Capabilities:" {
	ht=1
}

$0 ~ "VHT Capabilities" {
	vht=1
}

$0 ~ "HE Iftypes" {
	he=1
}

$1 == "*" && $3 == "MHz" && $0 !~ /disabled/ && band && !channel {
        channel = $4
}

END {
        print bands
}'
}

get_band_defaults() {
	local phy="$1"

	for c in $(__get_band_defaults "$phy"); do
		local band="${c%%:*}"
		c="${c#*:}"
		local chan="${c%%:*}"
		c="${c#*:}"
		local mode="${c%%:*}"

		case "$band" in
			1) band=2g;;
			2) band=5g;;
			3) band=60g;;
			4) band=6g;;
			*) band="";;
		esac

		[ -n "$band" ] || continue
		[ -n "$mode_band" -a "$band" = "6g" ] && return

		mode_band="$band"
		channel="$chan"
		htmode="$mode"
	done
}

detect_mac80211() {
	devidx=0
	config_load wireless
	while :; do
		config_get type "radio$devidx" type
		[ -n "$type" ] || break
		devidx=$(($devidx + 1))
	done

	for _dev in /sys/class/ieee80211/*; do
		[ -e "$_dev" ] || continue

		dev="${_dev##*/}"

		found=0
		config_foreach check_mac80211_device wifi-device
		[ "$found" -gt 0 ] && continue

		mode_band=""
		channel=""
		htmode=""
		ht_capab=""
		cell_density=""
		rx_stbc=""

		get_band_defaults "$dev"

		path="$(mac80211_phy_to_path "$dev")"
		if [ -x /usr/bin/readlink -a -h /sys/class/ieee80211/${dev} ]; then
			product=`cat $(readlink -f /sys/class/ieee80211/${dev}/device)/uevent | grep PRODUCT= | cut -d= -f 2`
			if [ -z "$product" ]; then
				driver=`cat $(readlink -f /sys/class/ieee80211/${dev}/device)/uevent | grep DRIVER= | cut -d= -f 2`
				# {{ added by friendlyelec
				# hack for ax200/mt7921/rtl8822ce
				case "${driver}" in
				"iwlwifi" | \
				"mt7921e" | \
				"rtw_8822ce")
					pci_id=`cat $(readlink -f /sys/class/ieee80211/${dev}/device)/uevent | grep PCI_ID= | cut -d= -f 2`
					product="pcie-${driver}-${pci_id}"
					;;
				"rtl88x2cs")
					sd_id=`cat $(readlink -f /sys/class/ieee80211/${dev}/device)/uevent | grep SDIO_ID= | cut -d= -f 2`
					product="sdio-${driver}-${sd_id}"
					;;
				esac
				# }}
			fi
		else
			product=""
		fi
		if [ -n "$path" ]; then
			dev_id="set wireless.radio${devidx}.path='$path'"
		else
			dev_id="set wireless.radio${devidx}.macaddr=$(cat /sys/class/ieee80211/${dev}/macaddress)"
		fi

		# {{ added by friendlyelec
		[ -n "$htmode" ] && ht_capab="set wireless.${name}.htmode=$htmode"
		case "${product}" in
		"bda/b812/210" | \
		"bda/c820/200")
			mode_band='2g'
			ht_capab="set wireless.radio${devidx}.htmode=HT20"
			channel=7
			country="set wireless.radio${devidx}.country='00'"
			;;

		# rtl88x2bu / rtl88x2cs
		"bda/b82c/210" | \
		"sdio-rtl88x2cs-024C:C822")
			mode_band='5g'
			ht_capab="set wireless.radio${devidx}.htmode=VHT80"
			rx_stbc="set wireless.radio${devidx}.rx_stbc='0'"
			channel=157
			country="set wireless.radio${devidx}.country='CN'"
			cell_density="set wireless.radio${devidx}.cell_density='0'"
			;;

		# ax200
		"pcie-iwlwifi-8086:2723")
			mode_band='2g'
			ht_capab="set wireless.radio${devidx}.htmode=HT40"
			channel=7
			country=""
			cell_density="set wireless.radio${devidx}.cell_density='0'"
			;;

		# mt7921 (pcie & usb)
		"pcie-mt7921e-14C3:7961" | \
		"e8d/7961/100")
			mode_band='5g'
			ht_capab="set wireless.radio${devidx}.htmode=HE80"
			channel=157
			country="set wireless.radio${devidx}.country='CN'"
			cell_density="set wireless.radio${devidx}.cell_density='0'"
			;;

		# rtl8822ce
		"pcie-rtw_8822ce-10EC:C822")
			mode_band='5g'
			ht_capab="set wireless.radio${devidx}.htmode=VHT80"
			channel=157
			country="set wireless.radio${devidx}.country='CN'"
			;;

		"bda/8812/0")
			country=""
			;;

		"bda/c811/200" | \
		"e8d/7612/100")
			country="set wireless.radio${devidx}.country='CN'"
			;;

		*)
			country=""
			;;

		esac

		ssid_suffix=$(cat /sys/class/ieee80211/${dev}/macaddress | cut -d':' -f1,2,6)
		if [ -z ${ssid_suffix} -o ${ssid_suffix} = "00:00:00" ]; then
			if [ -f /sys/class/net/eth0/address ]; then
				ssid_suffix=$(cat /sys/class/net/eth0/address | cut -d':' -f1,2,6)
			else
				ssid_suffix="1234"
			fi
		fi
		# }}

		uci -q batch <<-EOF
			set wireless.radio${devidx}=wifi-device
			set wireless.radio${devidx}.type=mac80211
			${dev_id}
			set wireless.radio${devidx}.channel=${channel}
			set wireless.radio${devidx}.band=${mode_band}
			set wireless.radio${devidx}.htmode=$htmode
			${ht_capab}
			${rx_stbc}
			${country}
			${cell_density}
			set wireless.radio${devidx}.disabled=1

			set wireless.default_radio${devidx}=wifi-iface
			set wireless.default_radio${devidx}.device=radio${devidx}
			set wireless.default_radio${devidx}.network=lan
			set wireless.default_radio${devidx}.mode=ap
			set wireless.default_radio${devidx}.ssid=FriendlyWrt-${ssid_suffix}
			set wireless.default_radio${devidx}.encryption=psk2
			set wireless.default_radio${devidx}.key=password
EOF
		uci -q commit wireless

		devidx=$(($devidx + 1))
	done
}
