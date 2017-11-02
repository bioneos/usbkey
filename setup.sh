#!/bin/bash

###
# Setup script for a newly created USBkey
#
# This script allows the target local user of the USBkey to appropriately 
# install the LUKS private key and shred the evidence on the USBkey.
#
# AUTHORS
#   Steven Davis <sgdavis@bioneos.com> 
#   Bio::Neos, Inc. <http://bioneos.com/>
#
# LICENSE
# Permission is hereby granted, free of charge, to any person obtaining a copy 
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

usbkey_root=".usbkey"
usbkey_image="linux.img"
usbkey_keyfile="key"
usbkey_osx_setup="osx-setup.sh"

# Arguments
usbkey_media=$1
user=$2

if [[ ! -f $usbkey_media/$user ]]; then
  su $user -c "DISPLAY=:0 notify-send -u critical \"** This USBkey was intended for a different user!! **(If you don't think this is correct: rename the target user file)\""
  exit 1
fi

# Get the user's home account
eval userhome=$(printf "~%q" $user)

logger -t usbkey "Installing USBkey for '$user'"

# Create secret
logger -t usbkey "Saving the stored secret: $userhome/$usbkey_root/$usbkey_keyfile"
mkdir -p $userhome/$usbkey_root
cp $usbkey_media/$usbkey_keyfile $userhome/$usbkey_root/
chmod 400 $userhome/$usbkey_root/$usbkey_keyfile
chmod 700 $userhome/$usbkey_root
chown -R $user $userhome/$usbkey_root
shred -n 7 -u $usbkey_media/$usbkey_keyfile

# Secure the SSH keys
logger -t usbkey "Safely storing SSH keys"
cryptsetup open --type luks --key-file $userhome/$usbkey_root/$usbkey_keyfile $usbkey_media/$usbkey_image usbkey
mount /dev/mapper/usbkey $usbkey_media/image
if [[ $? -ne 0 ]]; then
  logger -t usbkey "USBkey encrypted image failed to mount?"
  exit 1
fi
cp $usbkey_media/*_rsa* $usbkey_media/image/
chown $user $usbkey_media/image/*
chmod 400 $usbkey_media/image/*_rsa
chmod 644 $usbkey_media/image/*_rsa.pub

# Remove the keys (unless targeting OSX as well)
completed=0
if [[ ! -f $usbkey_media/$usbkey_osx_setup ]]; then
  shred -n 7 -u $usbkey_media/*_rsa*
  completed=1
fi

# Unmount / close
umount $usbkey_media/image
cryptsetup close usbkey

# Create EJECT indicator
logger -t usbkey "Creating EJECT indicator: $userhome/$usbkey_root/EJECT"
touch $userhome/$usbkey_root/EJECT
chown -R $user $userhome/$usbkey_root

# Notify of completion
if [[ $completed -eq 1 ]]; then
  # All done!
  su $user -c "DISPLAY=:0 notify-send \"USBkey setup completed. Ready to use!\""
else
  # Unprotected keys saved for OSX setup, remind the user to complete this
  su $user -c "DISPLAY=:0 notify-send -u critical \"USBkey setup completed for this workstation, but saved unprotected keys.** Remember to complete the OSX setup as soon as possible! **\""
fi
