#!/bin/bash

# Script to configure wireless networks .. 
# Written by Andrew Lear .. because I couldn't find one that worked for me

# It assumes the following packages have been installed
# dialog, wireless-tools, wpasupplicant

bailout() {
  rm -f "$TMP"
  rm -f "$WPATMP"
  exit $1
}


WLAN=$(cat /proc/net/dev | grep "wlan0")

if [[ ! $WLAN == *"wlan0"* ]]
then
  echo "Can't find wlan0";
  exit 1
fi

# Attempt to force the wireless channels we can use 
iw reg set GB > /dev/null 2>&1

TMP=$(mktemp)

EXITKEY="E"
EXITMENU="$EXITKEY Exit"

echo "Please wait while Wi-Fi networks are scanned"

wpa_cli terminate > /dev/null 2>&1
sleep 1
ifconfig wlan0 up > /dev/null 2>&1
sleep 1


WIRELESSNETWORKS=$(iwlist wlan0 scan | grep "ESSID:" | awk -F: '{print $2}' | uniq | sort)
# Remove quotation marks
WIRELESSNETWORKS=$(echo $WIRELESSNETWORKS | sed 's/"//g')

# Get the networks into an array
arrNETWORKS=(${WIRELESSNETWORKS//$'\n'/ })
len=${#arrNETWORKS[@]}

mycount=1
for (( i=0; i<${len}; i++ ));
do
  thisNET=${arrNETWORKS[$i]}
  echo $mycount $thisNET;
  DEVICELIST="$DEVICELIST $mycount $thisNET"
  ((mycount++))
done


dialog --menu "Select the Wi-Fi Network to Join" 18 60 12 $DEVICELIST $EXITMENU 2>"$TMP" || bailout
read JOINNET <"$TMP" ; rm -f "$TMP"
[ "$JOINNET" = "$EXITKEY" ] && bailout

# JOINNET is the number they have selected from the list, however it's indexed from 1 , so remove 1
JOINNET=$(( JOINNET - 1)) 

SELECTED_ESSID=${arrNETWORKS[$JOINNET]}

dialog --inputbox "Please enter the password for the '$SELECTED_ESSID' Wi-Fi Network" 10 70 "" 2>"$TMP" || bailout
read WIFI_PASSWORD <"$TMP" ; rm -f "$TMP"

# echo "You want to join $SELECTED_ESSID .. with the password of $WIFI_PASSWORD"

clear

echo "Creating /etc/wpa_supplicant/wpa_supplicant.conf"
sleep 1


echo "ctrl_interface=/var/run/wpa_supplicant" > /etc/wpa_supplicant/wpa_supplicant.conf
echo "network={" >> /etc/wpa_supplicant/wpa_supplicant.conf
echo "ssid=\"$SELECTED_ESSID\"" >> /etc/wpa_supplicant/wpa_supplicant.conf
echo "psk=\"$WIFI_PASSWORD\"" >> /etc/wpa_supplicant/wpa_supplicant.conf
echo "}" >> /etc/wpa_supplicant/wpa_supplicant.conf

echo "Attempting to bring wlan0 online via DHCP"

wpa_supplicant -B -iwlan0 -c/etc/wpa_supplicant/wpa_supplicant.conf -Dwext > /dev/null 2>&1
sleep 1
dhclient wlan0 > /dev/null 2>&1

VAR_IPV4=""
VAR_IPV4=`/sbin/ifconfig wlan0 | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}'`

if [ $VAR_IPV4 == "" ]; then
	echo "wlan0 doesn't appear to have an IP address"
	exit 1
fi

echo "wlan0 has an IPv4 address of $VAR_IPV4"
echo ""

