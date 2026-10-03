#! /usr/bin/bash
user="blueteam"
host="192.168.1.5"

scp ./busybox ./remoteInstallScript.sh $user@$host:/tmp

ssh -t $user@$host 'sudo bash /tmp/remoteInstallScript.sh'
