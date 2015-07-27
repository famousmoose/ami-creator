#!/bin/bash


set -e
set -u
set -x

function die() {
    echo "$@"
    exit 1
}

[ $EUID -eq 0 ] || die "must be root"



_basedir="$( cd $( dirname -- $0 )/.. && /bin/pwd )"

cachedir="${_basedir}/cache"
[ -d "${cachedir}" ] || mkdir "${cachedir}"

[ $# -eq 2 ] || die "usage: $0 <kickstart config file> <name> "

config="$( readlink -f ${1} )"
name="${2}"

## change to a well-known directory; doesn't have to make sense, just has to be
## consistent.
cd "$( dirname ${config} )"

dest_img="${name}.img"

## check for required programs
#which aws >/dev/null 2>&1 || die "need aws"
which e2fsck >/dev/null 2>&1 || die "need e2fsck"
which resize2fs >/dev/null 2>&1 || die "need resize2fs"
rpm -q python-imgcreate >/dev/null 2>&1 || die "need python-imgcreate package"
rpm -q qemu-img >/dev/null 2>&1 || die "need qemu-img package"

## create the image
if [ ! -e "${dest_img}" ]; then
    ${_basedir}/ami_creator/ami_creator.py -c "${config}" -n "${name}"
else
    echo "$dest_img already exists; not recreating"
fi

## create raw image
dd if=/dev/zero of=${name}.raw bs=1M count=1000

## partition volume
sfdisk ${name}.raw << EOF
0,,83,*
;
;
;
EOF

#loopback mount and activate partition
loop_dev=$(losetup -f)
losetup ${loop_dev} ${name}.raw
kpartx -a ${loop_dev}

mapper_dev=/dev/mapper/$(basename ${loop_dev})p1

while ! [ -e ${mapper_dev} ] ; do
  echo "waiting for partition"
  sleep 1
done

## write image to volume and resize the filesystem
dd if=${dest_img} of=${mapper_dev} bs=8M conv=fsync
e2fsck -f ${mapper_dev}
resize2fs ${mapper_dev}
#Hack for grub

ln -s ${mapper_dev} ${loop_dev}1
grub_device_map=$(mktemp)
echo "(hd0) ${loop_dev}" > $grub_device_map
echo -e  'root (hd0,0)\nsetup (hd0)' |grub --device-map=$grub_device_map  --batch

rm $grub_device_map

## create qcow
qemu-img convert -O qcow2 ${name}.raw ${name}.qcow2

#Clean up
rm ${loop_dev}1
kpartx -d ${loop_dev}
losetup -d ${loop_dev}
