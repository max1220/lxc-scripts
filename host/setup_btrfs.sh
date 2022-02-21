#!/bin/bash
set -eu
# This script configures btrfs support, including
# automatic bootable snapshot backups.
# You must have installed Debian 11 on a btrfs root filesystem for this already.

# Load required utils
. ./utils/log.sh


if [ -z "${1}" ]; then
	>&2 echo "Error: Need to supply configuration file as first parameter"
	exit 1
fi
LOG "Using btrfs configuration file: ${1}"
. "${1}"



if [ "${ENABLE_BTRFS}" != true ]; then
	exit 0
fi

# Get uuid of the btrfs partition
uuid="$(blkid -o value "${BTRFS_DISK}" | head -n 1)"


# install utils for btrfs
apt-get install -y --no-install-recommends btrfsmaintenance git make ca-certificates


# enable useful btrfs systemd services
systemctl enable btrfs-balance.timer btrfs-defrag.timer btrfs-scrub.timer btrfs-trim.timer


# create initial snapshot of /
LOG "Creating snapshot of /"
cd /
btrfs sub snapshot / "${BTRFS_SUBVOLUME}"

# set the default subvolume when mounting to the just created snapshot
btrfs sub list / | tail -n 1 | read -r _id id _reset;
btrfs sub set-default "${id}" /
LOG "Setting default subvolume to id=${id}"


# prepare mount for a chroot
LOG "Preparing chroot..."
LOG "Mounting subvol=@rootfs/${BTRFS_SUBVOLUME} from disk ${BTRFS_DISK} to /mnt"

mount -t btrfs -o "subvol=@rootfs/${BTRFS_SUBVOLUME}" "${BTRFS_DISK}" /mnt

for i in dev proc run sys; do
	LOG "Creating ${i}"
	rm -rf "/mnt/${i}"
	mkdir "/mnt/${i}"
	mount -o bind "/${i}" "/mnt/${i}"
done

LOG "Generatign fstab..."
grep -F -v "UUID=${uuid}" /etc/fstab > fstab.new.tmp
echo "# generated by host_btrfs.sh" >> fstab.new.tmp
echo "UUID=${uuid} / btrfs noatime,subvol=@rootfs/${BTRFS_SUBVOLUME}" >> fstab.new.tmp
for dir in $BTRFS_SUBVOLUME_DIRS; do
	echo "UUID=${uuid} ${dir} btrfs noatime,subvol=@rootfs/${BTRFS_SUBVOLUME}${dir} 0 0" >> fstab.new.tmp
done
mv fstab.new.tmp /mnt/etc/fstab

# create system service to update grub btrfs snapshot list on reboot
cat << EOF > /mnt/etc/systemd/system/grub-btrfs-reboot.service
[Unit]
Description=Update grub-btrfs.cfg before reboot/shutdown
Before=poweroff.target

[Service]
Type=oneshot
Environment="PATH=/sbin:/bin:/usr/sbin:/usr/bin"
EnvironmentFile=/etc/default/grub-btrfs/config
RemainAfterExit=true
ExecStart=/bin/true
ExecStop=bash -c 'if [ -s "\${GRUB_BTRFS_GRUB_DIRNAME:-/boot/grub}/grub-btrfs.cfg" ]; then /etc/grub.d/41_snapshots-btrfs; else \${GRUB_BTRFS_MKCONFIG:-grub-mkconfig} -o \${GRUB_BTRFS_GRUB_DIRNAME:-/boot/grub}/grub.cfg; fi'

[Install]
WantedBy=multi-user.target
EOF

# run in chroot:
LOG "Running chroot..."
cat << EOF | chroot /mnt /bin/bash
cd /

# remove old content of BTRFS_SUBVOLUME_DIRS in snapshot
for dir in ${BTRFS_SUBVOLUME_DIRS}; do
	rm -rf \$dir
done

# create sub-volume for each dir
for dir in ${BTRFS_SUBVOLUME_DIRS}; do
	btrfs sub create \$dir
done

# disable copy-on-write for /var, /tmp
chattr -R +C /var
chattr -R +C /tmp

# setup grub menu entries for btrfs snapshots
cd /root
git clone https://github.com/Antynea/grub-btrfs
cd grub-btrfs
make install

systemctl enable grub-btrfs-reboot

cd /
btrfs sub snapshot -r / fresh_install

exit 0
EOF

# copy current content to newly created volumes
for dir in $BTRFS_SUBVOLUME_DIRS; do
	LOG "Copying ${dir}..."
	mkdir -p "${dir}"
	cp -arf "${dir}" "/mnt"
done

LOG
LOG "BTRFS setup ok!"
LOG "Rebooting *highly* recommended(changes might be lost)!"
LOG