#! /bin/bash
set -x

mkdir -p /opt/cde-tools
cp /tmp/busybox /opt/cde-tools/busybox
chmod 755 /opt/cde-tools/busybox

echo "Adding busybox to path"
echo "export PATH=\"/opt/cde-tools:\$PATH\"" >>/etc/bash.bashrc
echo "export PATH=\"/opt/cde-tools:\$PATH\"" >>~/.bashrc
