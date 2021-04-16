#!/bin/bash
set -e

# This script is used to setup a LXC container host.
# Use it on a fresh install of Debian 10 with working internet connection.

# You also want to setup networking for the server.
# See host_network.sh for an example network setup(it's easily configurable)
# Things that (currently) need to be done manually:
# * setup mounts/fstab

### CONFIGURATION ###

# perform setup needed for cgroup v2(currently broken)
ENABLE_CGROUPV2=false

# enable setup for unprivileged containers(currently broken)
ENABLE_UNPRIVILEGED=false

# setup this user for use with unprivileged containers(needs to exist already)
USERNAME=max

### END CONFIGURATION ###




function LOG() {
	echo -e "\e[32m$@\e[0m"
}

# install apt-transport-https
apt-get update -y
apt-get upgrade -y
apt-get install -y apt-utils gnupg apt-transport-https ca-certificates

# install sources.list for stable that uses https
LOG "Setting up APT for https..."
cp /etc/apt/sources.list /etc/apt/sources.list.orig
cat << EOF > /etc/apt/sources.list
# use default CDN(fastly) over HTTPS, enable contrib and non-free
deb https://deb.debian.org/debian buster main contrib non-free
deb https://deb.debian.org/debian buster-updates main contrib non-free
deb https://deb.debian.org/debian-security buster/updates main
deb https://deb.debian.org/debian buster-backports main contrib non-free
EOF

# set debconf config value before installing so no promts are needed:

# no tunneling through apt-cacher-ng(this could bypass firewall rules)
echo "apt-cacher-ng apt-cacher-ng/tunnelenable boolean false" | debconf-set-selections

# don't save the current iptable rules(added later)
echo "apt-cacher-ng iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
echo "apt-cacher-ng iptables-persistent/autosave_v6 boolean false" | debconf-set-selections

# install required and nice-to-have packages
LOG "Installing required packages..."
apt-get update -y
#apt-get upgrade -y
apt-get dist-upgrade -y
apt-get install -y --no-install-recommends \
 sudo screen nano less bash-completion man-db dialog lua5.1 dnsutils netcat \
 openssh-server unattended-upgrades \
 systemd-journal-remote iptables-persistent apt-cacher-ng fail2ban certbot \
 lxc dnsmasq-base lxc-templates debootstrap rsync \
 uidmap apparmor apparmor-utils \
 linux-image-amd64/buster-backports



LOG "Updating kernel cmdline..."

# enable apparmor
echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT apparmor=1 security=apparmor\"" > /etc/default/grub.d/apparmor.cfg

# TODO: cgroupv2 currently not working
if [ "$ENABLE_CGROUPV2" = true ]; then
	echo "GRUB_CMDLINE_LINUX_DEFAULT=\"\$GRUB_CMDLINE_LINUX_DEFAULT systemd.unified_cgroup_hierarchy=1\"" > /etc/default/grub.d/cgroupv2.cfg
fi
update-grub


# enable LXC bridge
LOG "Enabling lxc-net..."
echo "USE_LXC_BRIDGE=\"true\"" > /etc/default/lxc-net
systemctl enable lxc-net
systemctl restart lxc-net


# modify default configuration to use cgroup v2 for device confinement
if [ "$ENABLE_CGROUPV2" = true ]; then
	LOG "Modifying default container configuration to use cgroupv2 devices"
	cp /usr/share/lxc/config/debian.common.conf /usr/share/lxc/config/debian.common.conf.orig
	cp /usr/share/lxc/config/common.conf /usr/share/lxc/config/common.conf.orig
	sed -i "s/lxc.cgroup.devices/lxc.cgroup2.devices/g" /usr/share/lxc/config/debian.common.conf
	sed -i "s/lxc.cgroup.devices/lxc.cgroup2.devices/g" /usr/share/lxc/config/common.conf
fi


# create directory for shared(public) data
mkdir -p /data/shared


# allow root to map itself to UID's >1M
LOG "Setting up subuid/subgid for root..."
echo "root:1000000:65536" >> /etc/subuid
echo "root:1000000:65536" >> /etc/subgid


if [ "$ENABLE_UNPRIVILEGED" = true ]; then
	LOG "Setting up subuid/subgid for $USERNAME..."
	echo "$USERNAME:2000000:65536" >> /etc/subuid
	echo "$USERNAME:2000000:65536" >> /etc/subgid

	LOG "Setting up to enable unprivileged_userns_clone..."
	cat << EOF > /etc/sysctl.d/30-userns.conf
kernel.unprivileged_userns_clone=0
EOF

	LOG "Setting up default.conf for unprivileged user $USERNAME"
	mkdir -p /home/$USERNAME/.config/lxc
	cat << EOF > .config/lxc/default.conf
lxc.apparmor.profile = unconfined
lxc.cap.drop = audit_control
lxc.cap.drop = audit_read
lxc.cap.drop = audit_write
lxc.cap.drop = sys_module
lxc.cap.drop = mac_admin
lxc.cap.drop = mac_override
lxc.cap.drop = sys_time
lxc.cap.drop = net_raw

lxc.idmap = u 0 2000000 65536
lxc.idmap = g 0 2000000 65536
lxc.mount.auto = proc:mixed sys:ro cgroup:mixed

EOF
	chown -R $USERNAME:$USERNAME /home/$USERNAME/.config
fi

# setup LXC default container config
LOG "Setting up LXC default.conf ..."
cp /etc/lxc/default.conf /etc/lxc/default.conf.orig
cat << EOF > /etc/lxc/default.conf
lxc.apparmor.profile = generated

lxc.start.auto = 1
lxc.cap.drop = audit_control
lxc.cap.drop = audit_read
lxc.cap.drop = audit_write
lxc.cap.drop = sys_module
lxc.cap.drop = mac_admin
lxc.cap.drop = mac_override
lxc.cap.drop = sys_time
lxc.cap.drop = net_raw

lxc.idmap = u 0 1000000 65536
lxc.idmap = g 0 1000000 65536

lxc.mount.auto = proc:mixed sys:ro cgroup:mixed

lxc.mount.entry=/data/shared data/shared none bind,optional,create=dir 0 0

EOF

# TODO: cgroupv2 currently not working
if [ "$ENABLE_CGROUPV2" = true ]; then
	cat << EOF >> /etc/lxc/default.conf
# disable cgroup v1
lxc.cgroup.devices.allow =
lxc.cgroup.devices.deny = a
# configure containers systemd to use cgroup v2
lxc.init.cmd = /lib/systemd/systemd systemd.unified_cgroup_hierarchy=1

EOF
fi




#setup fail2ban
rm /etc/fail2ban/jail.d/defaults-debian.conf
cat << EOF > /etc/fail2ban/10-local.conf
[DEFAULT]
bantime = 1h
ignorself = true
ignoreip = 127.0.0.1/8 ::1
bantime  = 10m
maxretry = 10
findtime = 5m
backend = systemd
logtarget = sysout

[sshd]
enabled = true
EOF



# setup apt-cacher-ng host
cp /etc/apt-cacher-ng/acng.conf /etc/apt-cacher-ng/acng.conf.orig
cat << EOF > /etc/apt-cacher-ng/acng.conf
BindAddress: 10.0.3.1
ConnectProto: v4

CacheDir: /var/cache/apt-cacher-ng
LogDir: /var/log/apt-cacher-ng
SupportDir: /usr/lib/apt-cacher-ng
LocalDirs: acng-doc /usr/share/doc/apt-cacher-ng
ReportPage: acng-report.html
ExThreshold: 7
EOF
systemctl enable apt-cacher-ng.service
systemctl restart apt-cacher-ng.service



# setup SSH server
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.orig
cat << EOF > /etc/ssh/sshd_config
# default values omitted for brevity
LogLevel VERBOSE
MaxAuthTries 5
MaxSessions 25
PermitRootLogin no
PermitEmptyPasswords no
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication no
IgnoreRhosts yes
HostbasedAuthentication no
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding yes
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server -f AUTHPRIV -l INFO
EOF
systemctl enable ssh
systemctl restart ssh



# setup remote logging for containers
cp /etc/systemd/journald.conf /etc/systemd/journald.conf.orig
cat << EOF > /etc/systemd/journald.conf
# See journald.conf(5) for details.
# default values omitted for brevity
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=2G
EOF

# change from HTTPS to HTTP
mkdir -p /etc/systemd/system/systemd-journal-remote.service.d
cat << EOF > /etc/systemd/system/systemd-journal-remote.service.d/override.conf
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-journal-remote --listen-http=-3 --output=/var/log/journal/remote/
LockPersonality=yes
LogsDirectory=journal/remote
MemoryDenyWriteExecute=yes
NoNewPrivileges=yes
PrivateDevices=yes
PrivateNetwork=yes
PrivateTmp=yes
ProtectControlGroups=yes
ProtectHome=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectSystem=strict
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
RestrictRealtime=yes
SystemCallArchitectures=native
User=systemd-journal-remote
WatchdogSec=3min

# If there are many split up journal files we need a lot of fds to access them
# all in parallel.
LimitNOFILE=524288
EOF

# only listen on container bridge IP
mkdir -p /etc/systemd/system/systemd-journal-remote.socket.d
cat << EOF > /etc/systemd/system/systemd-journal-remote.socket.d/override.conf
[Socket]
ListenStream=
ListenStream=10.0.3.1:19532
FreeBind=true
EOF
systemctl enable systemd-journal-remote
systemctl restart systemd-journal-remote



LOG
LOG "Host setup ok!"
LOG
#LOG "(press enter to return)"
#read
