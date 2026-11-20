#!/bin/sh

# Only procfs: ifconfig/ip block forever when rtnl_lock is stuck (wcn36xx crash).
IPADDR=$(awk '/^[ \t]*\|--/ { addr = $2 } /host LOCAL/ { print addr }' /proc/net/fib_trie 2>/dev/null | grep -v '^127\.' | sort -u | tr '\n' ' ')

if type sensors >/dev/null 2>&1; then
	CPUTMP=$(sensors 2>/dev/null | grep -Eo '\+[0-9]+.+C ' | sed ':a;N;$!ba;s/\n/ /g;s/+//g')
elif [ -f /sys/class/thermal/thermal_zone0/temp ]; then
	CPUTMP=$(awk '{ printf("%.1f °C", $0 / 1000) }' /sys/class/thermal/thermal_zone0/temp)
else
	CPUTMP=
fi

[ -n "$CPUTMP" ] && echo -e "TEMP.: \x1B[92m $CPUTMP\x1B[0m"
[ -n "$IPADDR" ] && echo -e "ADDR.: \x1B[92m $IPADDR\x1B[0m"
echo -e "STAT.: \x1B[92m$(uptime)\x1B[0m"
echo
uname -a
echo
