#! /usr/bin/bash
user="bluey"
host="192.168.57.254"

scp ./busybox ./remoteInstallScript.sh $user@$host:/tmp

ssh -t bluey@192.168.57.254 'sudo bash /tmp/remoteInstallScript.sh'
