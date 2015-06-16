#!/bin/bash

PATH="/bin:/sbin:/usr/bin:/usr/sbin"
export PATH

# get root
if [ $UID != 0 ]; then
 echo Error: become root before starting $0 >&2
 exit 100
fi

TMP=$(mktemp)
WPATMP=$(mktemp)

bailout() {
  rm -f "$TMP"
  rm -f "$WPATMP"
  exit $1
}

# This function produces the IWOURLINE for interfaces
writeiwline() {
  IWOURLINE=""
  if [ -n "$NWID" ]; then
    IWOURLINE="$IWOURLINE wireless-nwid $NWID\n"
  fi

  if [ -n "$MODE" ]; then
    IWOURLINE="$IWOURLINE wireless-mode $MODE\n"
  fi

  if [ -n "$CHANNEL" ]; then
    IWOURLINE="$IWOURLINE wireless-channel $CHANNEL\n"
  fi

  if [ -n "$FREQ" ]; then
    IWOURLINE="$IWOURLINE wireless-freq $FREQ\n"
  fi

  if [ -n "$KEY" ]; then
    if [ "$PUBKEY" -eq 1 ]; then
      # Store the key in interfaces in wireless-key
      IWOURLINE="$IWOURLINE wireless-key $KEY\n"
    else
      # Store the key in /etc/network/wep.$DV which is root readable only
      # Use pre-up in interfaces to read and set it
      echo "$KEY" > /etc/network/wep.$DV && chmod 600 /etc/network/wep.$DV && IWOURLINE="$IWOURLINE pre-up KEY=\$(cat /etc/network/wep.$DV) && iwconfig $DV key \$KEY\n"
    fi
  fi

  [ -d /sys/module/rt2??0/ ] && IWPREUPLINE="$IWPREUPLINE pre-up /sbin/ifconfig $DV up\n"

  if [ -n "$IWCONFIG" ]; then
    IWPREUPLINE="$IWPREUPLINE iwconfig $IWCONFIG\n"
  fi

  if [ -n "$IWSPY" ]; then
    IWPREUPLINE="$IWPREUPLINE iwspy $IWSPY\n"
  fi

  if [ -n "$IWPRIV" ]; then
    IWPREUPLINE="$IWPREUPLINE iwpriv $IWPRIV\n"
  fi

  # execute ESSID last, but make sure that it is written as first option
  if [ -n "$ESSID" ]; then
    IWOURLINE="$IWOURLINE wireless-essid $ESSID\n"
  fi

  if [ $WPAON -gt 0 ]; then
    # Using wpa requires a wpa_supplicant entry
    IWPREUPLINE="${IWPREUPLINE}pre-up wpa_supplicant -D$WPA_DEV -i$WLDEVICE -c/etc/wpa_supplicant.conf -B\n"
    touch /etc/wpa_supplicant.conf
    awk '/^network={/{if(found){found=0}else{found=1;hold=$0}}/ssid={/{if(/ssid='"$ESSID"'/){found=1}else{found=0;print hold}}{if(!found){print}}' /etc/wpa_supplicant.conf >> "$TMP"
    wpa_passphrase "$ESSID" "$WPASECRET" 2>/dev/null >> "$TMP"
    mv -f /etc/wpa_supplicant.conf /etc/wpa_supplicant.conf.$(date +%Y%m%d_%H%M)
    if ! grep -q "For more information take a look at" /etc/wpa_supplicant.conf ; then
      cat >$WPATMP <<EOF
# /etc/wpa_supplicant.conf
# For more information take a look at /usr/share/doc/wpasupplicant/
#
# Other WPA options:
#  scan_ssid [0]|1
#  bssid 00:11:22:33:44:55
#  priority [0]|Integer
#  proto [WPA RSN] WPA|RSN
#  key_mgmt [WPA-PSK WPA-EAP]|NONE|WPA-PSK|WPA-EAP|IEEE8021X
#  pairwise [CCMP TKIP]|CCMP|TKIP|NONE
#  group [CCMP TKIP WEP105 WEP40]|CCMP|TKIP|WEP105|WEP40
#  eapol_flags [3]|1|2

EOF
    fi
    [ -n "$APSCAN" ] && echo "$APSCAN" >> "$WPATMP"
    cat "$WPATMP" "$TMP" > /etc/wpa_supplicant.conf
    rm -f $WPATMP 2>/dev/null
    IWDOWNLINE="${IWDOWNLINE}down killall wpa_supplicant\n"
  fi

  IWOURLINE="$IWOURLINE $IWPREUPLINE $IWDOWNLINE"
  #echo "DEBUG: for interfaces $IWOURLINE"
}

device2props() {
  PARTCOUNT=0
  isauto=0
  isfirewire=0
  iswireless=0
  driver=""
  mac=""
  for PART in $DEVICE; do
    if [ $PARTCOUNT -eq 0 ]; then
      DEVICENAME=$PART
    else
      echo $PART | grep -q A::1 && isauto=1
      echo $PART | grep -q F::1 && isfirewire=1
      echo $PART | grep -q W::1 && iswireless=1
      [ -z "$driver" ] && driver=$(echo $PART|awk 'BEGIN {FS="::"} /^D:/{print $2}')
      [ -z "$mac" ] && mac=$(echo $PART|awk 'BEGIN {FS="::"} /^M:/{print $2}')
    fi
    ((PARTCOUNT++))
  done
}

props2string() {
  MY_DEVICE_NAME=""
  [ $isfirewire -gt 0 ] && MY_DEVICE_NAME="$NET_DEVICE_NAME_FW"
  [ -z "$MY_DEVICE_NAME" -a $iswireless -gt 0 ] && MY_DEVICE_NAME="$NET_DEVICE_NAME_W"
  [ -z "$MY_DEVICE_NAME" ] && MY_DEVICE_NAME="$NET_DEVICE_NAME"
  MY_DEVICE_NAME="$DEVICENAME $MY_DEVICE_NAME $mac $driver"
  [ $isauto -gt 0 ] && MY_DEVICE_NAME="$MY_DEVICE_NAME $NET_DEVICE_NAME_AUTO"
  MY_DEVICE_NAME=$(echo $MY_DEVICE_NAME | sed 's/\ /__/g')
}

addauto() {
  if ! egrep -e "^auto[  ]+.*$DV" /etc/network/interfaces >/dev/null; then
    awk '{if(/^auto/){if(done==0){print $0 " '"$DV"'";done=1}else{print}}else{print}}END{if(done==0){print "auto '$DV'"}}' "/etc/network/interfaces" > "$TMP"
    cat "$TMP" > /etc/network/interfaces
  fi
}

remauto(){
  if egrep -e "^auto[  ]+.*$DV" /etc/network/interfaces >/dev/null; then
    perl -pi -e 's/^(auto.*)'$DV'(.*)$/$1$2/;' /etc/network/interfaces
  fi
}

configiface() {
  [ ! -r /etc/network/interfaces ] && touch /etc/network/interfaces
  DEVICE=${NETDEVICES[$DV]}
  device2props
  DV=$DEVICENAME
  # wireless config
  WLDEVICE="$(LANG=C LC_MESSAGEWS=C iwconfig $DV 2>/dev/null | awk '/802\.11|READY|ESSID/{print $1}')"
  WLDEVICECOUNT="$(LANG=C LC_MESSAGEWS=C iwconfig $DV 2>/dev/null | wc -l)"
  if [ $iswireless -gt 0 ] && $DIALOG --yesno "$MESSAGE13" 8 45; then
    ESSID=""
    NWID=""
    MODE=""
    CHANNEL=""
    FREQ=""
    SENS=""
    RATE=""
    KEY=""
    RTS=""
    FRAG=""
    IWCONFIG=""
    IWSPY=""
    IWPRIV=""

    if [ -f /etc/network/interfaces ]; then
      awk '/iface/{if(/'"$DV"'/){found=1}else{found=0}}
        /essid/{if(found){for(i=NF;i>=2;i--)essid=$i "~" essid}}
        /nwid/{if(found){nwid=$NF}}
        /mode/{if(found){mode=$NF}}
        /channel/{if(found){channel=$NF}}
        /freq/{if(found){freq=$NF}}
        /sens/{if(found){sens=$NF}}
        /rate/{if(found){rate=$NF}}
        /rts/{if(found){rts=$NF}}
        /frag/{if(found){frag=$NF}}
        /iwconfig/{if(!/KEY/){if(found){iwconfig=$NF}}}
        /iwspy/{if(found){iwspy=$NF}}
        /iwpriv/{if(found){iwpriv=$NF}}
        /wireless[-_]key/{if(found){gsub(/^\W*wireless[-_]key\W*/,"");key=$0}}
        END{
          if (!(length(essid))){essid="~~~"}
          if (!(length(nwid))){nwid="~~~"}
          if (!(length(mode))){mode="~~~"}
          if (!(length(channel))){channel="~~~"}
          if (!(length(freq))){freq="~~~"}
          if (!(length(sens))){sens="~~~"}
          if (!(length(rate))){rate="~~~"}
          if (!(length(rts))){rts="~~~"}
          if (!(length(frag))){frag="~~~"}
          if (!(length(iwconfig))){iwconfig="~~~"}
          if (!(length(iwspy))){iwspy="~~~"}
          if (!(length(iwpriv))){iwpriv="~~~"}
          if (!(length(key))){key="~~~"}
          print essid" "nwid" "mode" "channel" "freq" "sens" "rate" "rts" "frag" "iwconfig" "iwspy" "iwpriv" "key
        }' /etc/network/interfaces >"$TMP"

      read ESSID NWID MODE CHANNEL FREQ SENS RATE RTS FRAG IWCONFIG IWSPY IWPRIV KEY<"$TMP"

      if [ "$ESSID" = "~~~" ]; then  ESSID=""; fi
      if [ "$NWID" = "~~~" ]; then  NWID=""; fi
      if [ "$MODE" = "~~~" ]; then  MODE=""; fi
      if [ "$CHANNEL" = "~~~" ]; then  CHANNEL=""; fi
      if [ "$FREQ" = "~~~" ]; then  FREQ=""; fi
      if [ "$SENS" = "~~~" ]; then  SENS=""; fi
      if [ "$RATE" = "~~~" ]; then  RATE=""; fi
      if [ "$RTS" = "~~~" ]; then  RTS=""; fi
      if [ "$FRAG" = "~~~" ]; then  FRAG=""; fi
      if [ "$IWCONFIG" = "~~~" ]; then IWCONFIG=""; fi
      if [ "$IWSPY" = "~~~" ]; then  IWSPY=""; fi
      if [ "$IWPRIV" = "~~~" ]; then  IWPRIV=""; fi
      if [ "$KEY" = "~~~" ]; then  KEY=""; fi

      ESSID=$(echo $ESSID | tr "~" " " | sed 's/ *$//')

      if [ -z "$KEY" ]; then
        KEY=$(cat /etc/network/wep.$DV 2>/dev/null)

        if [ -z "$KEY" ]; then
          PUBKEY=0
        else
          PUBKEY=-1
        fi
      else
        PUBKEY=1
      fi

      #echo "DEBUG:E:$ESSID N:$NWID M:$MODE C:$CHANNEL F:$FREQ S:$SENS R:$RATE K:$KEY R:$RTS F:$FRAG I:$IWCONFIG I:$IWSPY I:$IWPRIV"
      rm -f "$TMP"
    fi

    $DIALOG --inputbox "$MESSAGEW4 $DEVICENAME $MESSAGEW5" 15 50 "$ESSID" 2>"$TMP" || bailout 1
    read ESSID <"$TMP" ; rm -f "$TMP"
    [ -z "$ESSID" ] && ESSID="any"

    $DIALOG --inputbox "$MESSAGEW6 $DEVICENAME $MESSAGEW7" 15 50 "$NWID" 2>"$TMP" || bailout 1
    read NWID <"$TMP" ; rm -f "$TMP"

    $DIALOG --inputbox "$MESSAGEW8 $DEVICENAME $MESSAGEW9" 15 50 "$MODE" 2>"$TMP" || bailout 1
    read MODE <"$TMP" ; rm -f "$TMP"
    [ -z "$MODE" ] && MODE="Managed"

    $DIALOG --inputbox "$MESSAGEW10 $DEVICENAME $MESSAGEW11" 15 50 "$CHANNEL" 2>"$TMP" || bailout 1
    read CHANNEL <"$TMP" ; rm -f "$TMP"

    if [ -z "$CHANNEL" ]; then
      $DIALOG --inputbox "$MESSAGEW12 $DEVICENAME $MESSAGEW13" 15 50 "$FREQ" 2>"$TMP" || bailout 1
      read FREQ <"$TMP" ; rm -f "$TMP"
    fi

    WPAON=0
    IWDRIVER=$driver

    case $IWDRIVER in
      ath_pci)
        WPA_DEV="madwifi"
        ;;
      ipw2200|ipw2100)
        WPA_DEV="wext"
        ;;
      hostap)
        WPA_DEV="hostap"
        ;;
    esac

    if [ -z "$WPA_DEV" ]; then
      if [ -d /proc/net/ndiswrapper/$DV ]; then
        WPA_DEV=ndiswrapper
      elif [ -d /proc/net/hostap/$DV ]; then
        WPA_DEV=hostap
      elif [ $WLDEVICECOUNT -eq 1 ]; then
        if [ -e /proc/driver/atmel ]; then
          WPA_DEV=atmel
        fi
      fi
    fi

    WPAON=-1

    if [ -n "$WPA_DEV" ]; then
      if $DIALOG --yesno "$MESSAGEW22" 15 50; then
        # Other wpa options
        # scan_ssid [0]|1
        # bssid 00:11:22:33:44:55
        # priority [0]|Integer
        # proto [WPA RSN] WPA|RSN
        # key_mgmt [WPA-PSK WPA-EAP]|NONE|WPA-PSK|WPA-EAP|IEEE8021X
        # pairwise [CCMP TKIP]|CCMP|TKIP|NONE
        # group [CCMP TKIP WEP105 WEP40]|CCMP|TKIP|WEP105|WEP40
        # eapol_flags [3]|1|2

      if ! $DIALOG --yesno "Is SSID broadcast enabled?" 15 50; then
        APSCAN="ap_scan=2"
      fi
        WPAON=1
        KEY=""
        WPASECRET=$(awk	'/network/{if(found){found=0}else{found=1}}/ssid/{if(/ssid="'"$ESSID"'"/){found=1}else{found=0}}/#scan_ssid=1/#psk=/{if(found){gsub(/^\W*#psk="/,"");gsub(/"\W*$/,"");print}}' /etc/wpa_supplicant.conf)

        $DIALOG --inputbox "$MESSAGEW23 $ESSID" 15 50 "$WPASECRET" 2>"$TMP" || bailout 1
        WPASECRET=$(sed -e 's/\\/\\/g' "$TMP") && rm -r "$TMP"

        case $WPA_DEV in
          hostap)
            MODE="Managed"
            ;;
        esac
      else
        WPASECRET=""
      fi
    else
      WPASECRET=""
    fi

    # No need for a wep key if we are using wpa
    if [ ! $WPAON -eq 1 ]; then
      $DIALOG --inputbox "$MESSAGEW14 $DEVICENAME $MESSAGEW15" 15 50 "$KEY" 2>"$TMP" || bailout 1
      read KEY <"$TMP" ; rm -f "$TMP"

      if [ -n "$KEY" -a "$PUBKEY" -eq 0 ]; then
        if ! $DIALOG --yesno "$MESSAGEW25 $DEVICENAME $MESSAGEW26" 15 50; then
          PUBKEY=1
        fi
      fi
    fi

    $DIALOG --inputbox "$MESSAGEW16 $DEVICENAME $MESSAGEW17" 15 50 "$IWCONFIG" 2>"$TMP" || bailout 1
    read IWCONFIG <"$TMP" ; rm -f "$TMP"

    $DIALOG --inputbox "$MESSAGEW18 $DEVICENAME $MESSAGEW19" 15 50 "$IWSPY" 2>"$TMP" || bailout 1
    read IWSPY <"$TMP" ; rm -f "$TMP"

    $DIALOG --inputbox "$MESSAGEW20 $DEVICENAME $MESSAGEW21" 15 50 "$IWPRIV" 2>"$TMP" || bailout 1
    read IWPRIV <"$TMP" ; rm -f "$TMP"

    writeiwline
  fi

  if $DIALOG --yesno "$MESSAGE2" 8 45; then
    if [ -w /etc/network/interfaces ]; then
      rm -f "$TMP"
      awk '/iface/{if(/'"$DV"'/){found=1}else{found=0}}
        /^\W$/{if(blank==0){lastblank=1}else{lastblank=0}{blank=1}}
        /\w/{blank=0;lastblank=0}
        {if(!(found+lastblank)){print}}
        END{print "iface '"$DV"' inet dhcp"}' \
        /etc/network/interfaces >"$TMP"
      echo -e "$IWOURLINE" >> $TMP
      #echo -e "\n\n" >> $TMP
      cat "$TMP" >/etc/network/interfaces
      rm -f "$TMP"
      # Add an "auto" entry
      #addauto
    fi
  else
    if [ -f /etc/network/interfaces ]; then
      awk '/iface/{if(/'"$DV"'/){found=1}else{found=0}}
        /address/{if(found){address=$NF}}
        /netmask/{if(found){netmask=$NF}}
        /broadcast/{if(found){broadcast=$NF}}
        /gateway/{if(found){gateway=$NF}}
        END{print address" "netmask" "broadcast" "gateway}' /etc/network/interfaces >"$TMP"
      read IP NM BC DG <"$TMP"
      rm -f "$TMP"
    fi

    $DIALOG --inputbox "$MESSAGE6 $DV" 10 45 "${IP:-192.168.0.100}" 2>"$TMP" || bailout 1
    read IP <"$TMP" ; rm -f "$TMP"

    $DIALOG --inputbox "$MESSAGE7 $DV" 10 45 "${NM:-255.255.255.0}" 2>"$TMP" || bailout 1
    read NM <"$TMP" ; rm -f "$TMP"

    $DIALOG --inputbox "$MESSAGE8 $DV" 10 45 "${BC:-${IP%.*}.255}" 2>"$TMP" || bailout 1
    read BC <"$TMP" ; rm -f "$TMP"

    $DIALOG --inputbox "$MESSAGE9" 10 45 "${DG:-${IP%.*}.1}" 2>"$TMP"
    read DG <"$TMP" ; rm -f "$TMP"

    if [ -f "/etc/resolv.conf" ]; then
      NS="$(awk '/^nameserver/{printf "%s ",$2}' /etc/resolv.conf)"
    fi

    $DIALOG --inputbox "$MESSAGE10" 10 58 "${NS:-${IP%.*}.254}" 2>"$TMP"
    read NS <"$TMP" ; rm -f "$TMP"
    
    # --- added by AndrewLear to get DNS Domain Name
    if [ -f "/etc/resolv.conf" ]; then
      DOMAINNAME="$(awk '/^domain/{printf "%s ",$2}' /etc/resolv.conf)"
    fi

    $DIALOG --inputbox "$MESSAGE16" 10 58 "${DOMAINNAME}" 2>"$TMP"
    read DOMAINNAME <"$TMP" ; rm -f "$TMP"
    # --- end of DNS Domain Name
    
    
    # --- added by AndrewLear to get DNS Suffix Search List
    if [ -f "/etc/resolv.conf" ]; then
      SEARCHLIST="$(awk '/^search/{printf "%s ",$2}' /etc/resolv.conf)"
    fi

    $DIALOG --inputbox "$MESSAGE18" 10 65 "${SEARCHLIST}" 2>"$TMP"
    read SEARCHLIST <"$TMP" ; rm -f "$TMP"
    # --- end of DNS Suffix Search List
    
       
    
    
    

    if [ -w /etc/network/interfaces ]; then
      awk '/iface/{if(/'"$DV"'/){found=1}else{found=0}}
        {if(!found){print}}
        END{print "\niface '"$DV"' inet static\n\taddress '"$IP"'\n\tnetmask '"$NM"'\n\tnetwork '"${IP%.*}.0"'";if("'"$BC"'"!=""){print "\tbroadcast '"$BC"'"};if("'"$DG"'"!=""){print "\tgateway '"$DG"'"};if("'"$IWOURLINE"'"!=""){print "'"$IWOURLINE"'"};print "\n"}' \
        /etc/network/interfaces >"$TMP"

      cat "$TMP" >/etc/network/interfaces
      rm -f "$TMP"

      # Add an "auto" entry
      #addauto
    fi

    if [ -n "$NS" ]; then
      more=""

      for i in $NS; do
        if [ -z "$more" ]; then
          more=yes
          echo "$MESSAGE11 $i"
          echo "nameserver $i" >/etc/resolv.conf
        else
          echo "$MESSAGE12 $i"
          echo "nameserver $i" >>/etc/resolv.conf
        fi
      done
    fi
    
    if [ -n "$DOMAINNAME" ]; then
      echo "$MESSAGE17 $DOMAINNAME"
      echo "domain $DOMAINNAME" >> /etc/resolv.conf
    fi
    
    if [ -n "$SEARCHLIST" ]; then
      echo "$MESSAGE19 $SEARCHLIST"
      echo "search $SEARCHLIST" >> /etc/resolv.conf
    fi
    
  fi
  clear
  echo "Network configuration updated"
  echo ""
}

DIALOG="dialog"
export XDIALOG_HIGH_DIALOG_COMPAT=1
[ -n "$DISPLAY" ] && [ -x /usr/bin/Xdialog ] && DIALOG="Xdialog"
[ -f /etc/sysconfig/i18n ] && . /etc/sysconfig/i18n

# Default all strings to English
NET_DEVICE_NAME="Network_device"
NET_DEVICE_NAME_W="Wireless_device"
NET_DEVICE_NAME_FW="Firewire_device"
NET_DEVICE_NAME_AUTO="Auto"
MESSAGE0="No supported network cards found."
MESSAGE1="Please select network device"
MESSAGE2="Use DHCP broadcast?"
MESSAGE3="Sending DHCP broadcast from device"
MESSAGE4="Failed."
MESSAGE5="Hit return to exit."
MESSAGE6="Please enter IP Address for "
MESSAGE7="Please enter Network Mask for "
MESSAGE8="Please enter Broadcast Address for "
MESSAGE9="Please enter Default Gateway"
MESSAGE10="Please enter Nameserver(s) (space as the seperator)"
MESSAGE11="Setting Nameserver in /etc/resolv.conf to"
MESSAGE12="Adding Nameserver to /etc/resolv.conf:"
MESSAGE13="Setup wireless options?"
MESSAGE14="Failed to bring up the interface, would you like to reconfigure it?"
MESSAGE15="Interface enabled, do you want it auto enabled at boot?"

MESSAGE16="Please enter the DNS Domain Name"
MESSAGE17="Setting domain in /etc/resolv.conf to"

MESSAGE18="DNS suffix search list (space to seperator, 6 entries max)"
MESSAGE19="Setting search in /etc/resolv.conf to"

MESSAGEW0="No wireless network card found."
MESSAGEW1="Configuration of wireless parameters for"
MESSAGEW3="Please configure IP parameters of the interface first"
MESSAGEW4="Enter the ESSID for"
MESSAGEW5="\n\n\n(empty for 'any', not recommended !)\n"
MESSAGEW6="Enter the NWID (cell identifier)\nfor"
MESSAGEW7=", if needed\n\n\n"
MESSAGEW8="Enter the mode for"
MESSAGEW9="\n\n(Managed(=default), Ad-Hoc, Master,\nRepeater, Secondary, auto)\n"
MESSAGEW10="Enter channel number for"
MESSAGEW11="\n\n(0 bis 16, empty for auto or if you want to\n enter the frequency next)\n"
MESSAGEW12="Enter the frequency for"
MESSAGEW13="\n\n(e.g 2.412G, empty for auto)"
MESSAGEW14="Enter the encryption key\nfor"
MESSAGEW15="\n\n(empty for cleartext, not recommended !!)"
MESSAGEW16="Enter additional parameters for\n'iwconfig"
MESSAGEW17="' if needed, e.g.\n\n\nsens -80  rts 512  frag 512  rate 5.5M"
MESSAGEW18="Enter additional parameters for\n'iwspy"
MESSAGEW19="' if needed\n\n\n"
MESSAGEW20="Enter additional parameters for\n'iwpriv"
MESSAGEW21="' if needed\n\n\n"
MESSAGEW22="Enable WPA support?"
MESSAGEW23="Enter the WPA passphrase (passphrase must be 8..63 characters) for"
MESSAGEW25="Would you like to store your wep key in it's own private file ("
MESSAGEW26=")?   If you say no, your wep key will be stored in /etc/network/interfaces and will be readable by any account on your system.  You may want to 'chmod 600 /etc/network/interfaces' if you answer no to this question"
MESSAGEW27="Is SSID broadcast enabled?"


NETDEVICESCOUNT=0
LAN=$(tail -n +3 /proc/net/dev|awk -F: '{print $1}'|sed "s/\s*//"|grep -v -e ^lo -e ^vmnet|sort)
[ -n "$WLAN" ] || WLAN=$(tail -n +3 /proc/net/wireless|awk -F: '{print $1}'|sort)
unset LAN_DEVICES WLAN_DEVICES FIREWIRE_DEVICES NETDEVICES
while read dev mac; do
#echo "Making NETDEVICES $NETDEVICESCOUNT $dev"
  iswlan=$(echo $dev $WLAN|tr ' ' '\n'|sort|uniq -d)
  isauto="0"
  grep auto /etc/network/interfaces | grep -q $dev && isauto="1"
  driver=$(ethtool -i $dev 2>/dev/null|awk '/^driver:/{print $2}')
  if [ "$driver" ]; then
    if [ "$iswlan" ]; then
      NETDEVICES[$NETDEVICESCOUNT]="$dev A::$isauto M::$mac D::$driver W::1 F::0"
    else
      NETDEVICES[$NETDEVICESCOUNT]="$dev A::$isauto M::$mac D::$driver W::0 F::0"
    fi
  else
    if [ "$iswlan" ]; then
      NETDEVICES[$NETDEVICESCOUNT]="$dev A::$isauto M::$mac W::1 F::0"
    else
      NETDEVICES[$NETDEVICESCOUNT]="$dev A::$isauto M::$mac W::0 F::0"
    fi
  fi
#echo "Made to ${NETDEVICES[$NETDEVICESCOUNT]}"
  ((NETDEVICESCOUNT++))
done < <(ifconfig -a|grep Ethernet|grep -v ^vmnet|awk '! /^\s/{print $1" "$5}')
for dev in $LAN; do
  if [ "$(ethtool -i $dev 2>/dev/null|awk '/^bus-info:/{print $2}')" == "ieee1394" ]; then
    isauto="0"
    grep auto /etc/network/interfaces | grep -q $dev && isauto="1"
    NETDEVICES[$NETDEVICESCOUNT]="$dev A::$isauto D::$(ethtool -i $dev 2>/dev/null|awk '/^driver:/{print $2}') W::0 F::1"
    ((NETDEVICESCOUNT++))
  fi
done

#NETDEVICES="$(cat /proc/net/dev | awk -F: '/eth.:|lan.:|tr.:|wlan.:|ath.:|ra.:/{print $1}')"

if [ -z "$NETDEVICES" ]; then
  $DIALOG --msgbox "$MESSAGE0" 15 45
  bailout
fi

count="$NETDEVICESCOUNT"

if [ "$count" -gt 1 ]; then
  DEVICELIST=""
  mycount=0
  while [ $mycount -lt $count ]; do
    DEVICE=${NETDEVICES[$mycount]}
#echo "$mycount is $DEVICE"
    device2props
#echo "name: $DEVICENAME auto: $isauto fw: $isfirewire mac: $mac driver: $driver"
    props2string
    DEVICELIST="$DEVICELIST $mycount $MY_DEVICE_NAME"
    ((mycount++))
  done
fi

# To translate
EXITKEY="E"
EXITMENU="$EXITKEY Exit"

# main program loop until they bailout
while (true); do
  # first get the device
  if [ "$count" -gt 1 ]; then
    rm -f "$TMP"
    $DIALOG --menu "$MESSAGE1" 18 60 12 $DEVICELIST $EXITMENU 2>"$TMP" || bailout
    read DV <"$TMP" ; rm -f "$TMP"
    [ "$DV" = "$EXITKEY" ] && bailout
  else
    # Only one device
    DV=0
    # they have asked to stop configuring the interface so exit
    [ -z "$IFACEDONE" ] || bailout
  fi
  # device config loop
  IFACEDONE=""
  while [ -n "$DV" -a -z "$IFACEDONE" ]; do
    configiface
    ifdown $DV
    sleep 3
    if ! ifup $DV; then
      $DIALOG --yesno "$MESSAGE14" 15 50 || IFACEDONE="DONE"
    else
      # Commented out, since this makes no sense on a Live CD
      # $DIALOG --yesno "$MESSAGE15" 15 50 && addauto || remauto
      IFACEDONE="DONE"
    fi
  done
done

## END OF FILE #################################################################
