#!/bin/bash

###
# Setup script for "usbkey"
# USB Key based SSH key management
#
# DEPENDENCIES
# 'ssh-askpass-fullscreen' : Used to get the encryption password
# 'cryptosetup' : Used to create the LUKS encrypted file
# 'ssh-keygen'  : Used for SSH key generation
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

# Check for cryptsetup
check_cryptsetup=`which cryptsetup`
if [[ -z $check_crypsetup ]]; then
  echo
  echo "Cannot continue without cryptsetup..."
#  exit 1
fi

# Read the target user from the command line
echo -n "Enter target workstation username> "
read user
echo
echo "Creating USBkey for '$user':"
echo "====="

# Get the email for the GPG key
echo -n "Please enter the email address for your GPG key we should use> "
read email

# Check for a GPG secret key
check_gpg_secret=`su - $user -c "gpg --list-secret-key $email"`
if [[ -z $check_gpg_secret ]]; then
  echo
  echo "No GPG secret keys exist for '$email'. Please create the key first..."
  # Cannot continue
  exit 2
fi

# Create loopback device (1GB)
echo "Creating file for encypted image..."
dd if=/dev/zero of=linux.img bs=1 count=0 seek=100M

# Prompt for encryption passphrase
pass="none"
pass_check=""
until [[ $pass == $pass_check ]]; do
  echo -n "Enter the password for the encrypted image (Will not echo)> "
  read -s pass
  echo
  echo -n "Again> "
  read -s pass_check
  echo
  if [[ $pass != $pass_check ]]; then echo "Doesn't match!"; fi
done

# Prompt for encryption password
echo "Formatting device..."
printf $pass | cryptsetup luksFormat linux.img -

# Open encrypted image, and format filesystem
echo "Creating a file system"...
printf $pass | cryptsetup open --type luks linux.img usbkey
mkfs.ext4 /dev/mapper/usbkey

# Create SSH keys
echo "Creating SSH keys [secure, server, workstation]"
mkdir -p image/
mount /dev/mapper/usbkey image/
ssh-keygen -t rsa -b 4096 -C "$user@bioneos.com(secure)" -f image/secure_rsa
ssh-keygen -t rsa -C "$user@bioneos.com(server)" -f image/server_rsa
ssh-keygen -t rsa -C "$user@bioneos.com(workstation)" -f image/workstation_rsa
chown $user image/*
umount image/
cryptsetup close usbkey

# Create secret
echo "Creating the stored secret. Please enter your GPG UserID for your private key:"
su $user -c "echo \"$pass\" | gpg --encrypt -o /tmp/$user.gpg -r $email"
mv /tmp/$user.gpg .

# Verify secret
secret=$(/bin/su ${user} -c "gpg --decrypt ${user}.gpg")
printf $secret | cryptsetup open --type luks linux.img usbkey
check_secret=$?
cryptsetup close usbkey
echo
echo
if [[ $check_secret -eq 0 ]]; then
  # Create EJECT indicator
  echo > ${mount_point}/EJECT
  # All Done!
  echo "Completed setup!!"
else
  echo "Done... but secret failed to decrypt or open encrypted partition."
  echo
  echo "** Review the setup before attempting to use **"
fi
