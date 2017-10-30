#!/bin/bash

###
# Setup script for "usbkey"
# USB Key based SSH key management
#
# DEPENDENCIES
# 'cryptsetup' : Used to create the LUKS encrypted file.
# 'ssh-keygen'  : Used for SSH key generation.
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

# Adjust as needed:
usbkey_install="/usr/local/usbkey/"
usbkey_osx_support="osx-setup.sh"
usbkey_image="linux.img"
usbkey_root=".usbkey"
usbkey_keyfile="$usbkey_root/key"

# Check for cryptsetup
check_cryptsetup=`which cryptsetup`
if [[ -z $check_cryptsetup ]]; then
  echo
  echo "Cannot continue without 'cryptsetup' (are you root?)..."
  exit 1
fi

# Read the target user from the command line
user=""
userhome=""
until [[ -n $user ]] && [[ -d $userhome ]]; do
  echo -n "Target workstation username? "
  read user

  # Test for valid username
  id "$user" 1>/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    echo "User '$user' not found!"
    user=""
  fi

  # Get the user's home account
  eval userhome=$(printf "~%q" $user)
done
echo
echo "Creating USBkey for '$user':"
echo "====="

# Create loopback device (100MB)
echo "Creating file for encypted image..."
fallocate -l 100M $usbkey_image

# Create secret
echo "Creating the stored secret ($usbkey_keyfile)..."
mkdir -p $userhome/$usbkey_root
dd bs=512 count=4 if=/dev/urandom of=$userhome/$usbkey_keyfile
chmod 400 $userhome/$usbkey_keyfile
chmod 700 $userhome/$usbkey_root
chown $user -R $userhome/$usbkey_root
echo
echo "** NOTE: Remember to keep this file secret!! **"
echo "** If it is compromised, delete it and issue new keys **"
echo

# Format the device using the keyfile first
echo "Formatting device..."
cryptsetup -q luksFormat $usbkey_image $userhome/$usbkey_keyfile

# Determine if we will add a passphrase as well
echo -n "Would you like to use a passphrase as well (y/N)? "
read create_passphrase
if [[ $create_passphrase == "y" ]] || [[ $create_passphrase == "Y" ]]; then
  # Prompt for encryption passphrase
  pass="none"
  pass_check=""
  until [[ $pass == $pass_check ]]; do
    echo -n "  Password for the encrypted image (Will not echo)? "
    read -s pass
    echo
    echo -n "  Again? "
    read -s pass_check
    echo
    if [[ $pass != $pass_check ]]; then echo "    Doesn't match!"; fi
  done

  # Adding passphrase
  printf $pass | cryptsetup luksAddKey --key-file $userhome/$usbkey_keyfile $usbkey_image -
fi

# Open encrypted image, and format filesystem
echo "Creating a file system"...
cryptsetup open --type luks --key-file $userhome/$usbkey_keyfile $usbkey_image usbkey
mkfs.ext4 /dev/mapper/usbkey

# Add the OSX support?
echo -n "Would you like to add OSX support as well (y/N)? "
read support_osx
# Create SSH keys
echo "Creating SSH keys [secure, server, workstation]..."
mkdir -p image/
mount /dev/mapper/usbkey image/
ssh-keygen -N '' -t rsa -b 4096 -C "$user@bioneos.com(secure)" -f image/secure_rsa
ssh-keygen -N '' -t rsa -C "$user@bioneos.com(server)" -f image/server_rsa
ssh-keygen -N '' -t rsa -C "$user@bioneos.com(workstation)" -f image/workstation_rsa
chown $user image/*

# Create setup for OSX if desired
if [[ $support_osx == "y" ]] || [[ $support_osx == "Y" ]]; then
  cp image/* .
  cp $usbkey_install/$usbkey_osx_support .
  echo
  echo "** NOTE: additional setup using an OSX device is required **"
  echo " A duplicate of the SSH keys are stored on this drive, unencrypted."
  echo " This should be considered unsafe until you run the '$usbkey_osx_support' scrupt."
  echo " to setup your OSX passphrase and complete the setup.."
  echo
fi
umount image/
cryptsetup close usbkey

# Create EJECT indicator
touch $userhome/$usbkey_root/EJECT
chown $user $userhome/$usbkey_root/EJECT

# All Done!
echo
echo "Completed setup!!"
