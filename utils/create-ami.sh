#!/bin/bash

## @todo check if ami name already exists

set -e
set -u
# set -x

function die() {
    echo "$@"
    exit 1
}

[ $EUID -eq 0 ] || die "must be root"

export EC2_URL=https://ec2.amazonaws.com/

KERNELID=aki-b4aa75dd 

_basedir="$( cd $( dirname -- $0 )/.. && /bin/pwd )"

cachedir="${_basedir}/cache"
[ -d "${cachedir}" ] || mkdir "${cachedir}"

[ $# -eq 4 ] || die "usage: $0 <kickstart config file> <ami name> <ebs block device> <ebs vol id>"

config="$( readlink -f ${1} )"
ami_name="${2}"
block_dev="${3}"
vol_id="${4}"

## change to a well-known directory; doesn't have to make sense, just has to be
## consistent.
cd "$( dirname ${config} )"

name="$( basename $config | sed -r -e 's#\.[^.]+$##g' )"
dest_img="${name}.img"

## check for required programs
#which aws >/dev/null 2>&1 || die "need aws"
which curl >/dev/null 2>&1 || die "need curl"
which e2fsck >/dev/null 2>&1 || die "need e2fsck"
which resize2fs >/dev/null 2>&1 || die "need resize2fs"
rpm -q python-imgcreate >/dev/null 2>&1 || die "need python-imgcreate package"
rpm -q euca2ools >/dev/null 2>&1 || die "need euca2ools package"

## the block device must exist
[ -e "${block_dev}" ] || die "${block_dev} does not exist"

## volume should be attached to this instance
my_instance_id="$( curl -s http://169.254.169.254/latest/meta-data/instance-id )"

## set up/verify aws credentials and settings
## http://docs.aws.amazon.com/cli/latest/userguide/cli-chap-getting-started.html
export EC2_DEFAULT_REGION="$( curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed -e 's#.$##g' )"
[ -n "${EC2_ACCESS_KEY}" ] || die "EC2_ACCESS_KEY not set"
[ -n "${EC2_SECRET_KEY}" ] || die "EC2_SECRET_KEY not set"

if [ "$( euca-describe-volumes ${vol_id} | grep -Eo 'i-[0-9a-f]+')" != "${my_instance_id}" ]; then
    die "volume ${vol_id} is not attached to this instance!"
fi

## create the image
if [ ! -e "${dest_img}" ]; then
    ${_basedir}/ami_creator/ami_creator.py -c "${config}" -n "${name}"
else
    echo "$dest_img already exists; not recreating"
fi

## partition volume
sfdisk ${block_dev} << EOF
0,,83,*
;
;
;
EOF

## write image to volume and resize the filesystem
dd if=${dest_img} of=${block_dev}1 bs=8M
e2fsck -f ${block_dev}1
resize2fs ${block_dev}1

## create a snapshot of the volume
snap_id=$( euca-create-snapshot --description "root image for ${name}" ${vol_id} | grep -Eo 'snap-[0-9a-f]+' )

while [ "$( euca-describe-snapshots ${snap_id} | awk '{ print $4 }' )" != "completed" ]; do
    echo "waiting for snapshot ${snap_id} to complete"
    sleep 5
done

## kernel-id hard-coded
## see http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/UserProvidedKernels.html
image_id=$( euca-register --kernel ${KERNELID} --architecture x86_64 --name "${ami_name}" --root-device-name /dev/sda1 --block-device-mapping="/dev/sda=${snap_id}:6" --block-device-mapping="/dev/sdb=ephemeral0" | grep -Eo 'ami-[0-9a-f]+' )

echo "created AMI with id ${image_id}"
