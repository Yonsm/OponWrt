#!/bin/sh

IPADDR=`ifconfig -a|grep inet|grep -v 127.0.0.1|grep -v inet6|awk '{print $2}'|tr -d 'addr:'|tr '\n' ' '`

if type sensors > /dev/null; then CPUTMP=`sensors | grep -Eo '\+[0-9]+.+C ' | sed ':a;N;$!ba;s/\n/ /g;s/+//g'`
elif [ -f /sys/class/thermal/thermal_zone0/temp ]; then CPUTMP=`awk '{ printf("%.1f °C", $0 / 1000) }' /sys/class/thermal/thermal_zone0/temp`
else CPUTMP=
fi

[ ! -z "$CPUTMP" ] && echo -e "环境温度：\x1B[92m $CPUTMP\x1B[0m"
[ ! -z "$IPADDR" ] && echo -e "网络地址：\x1B[92m $IPADDR\x1B[0m"
echo -e "运行时间：\x1B[92m`uptime`\x1B[0m"
echo
uname -a
echo
