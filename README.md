# USBKey 

The USBkey system is our internal system for managing remote login keys to minimizing password entry and hopefully increase security for our systems. This system was designed internally after careful thought and research, but without external review or input. **If you would like to provide your comments or suggestions on the system design, we would appreciate the input!** Simply create an [Issue]:(https://github.com/bioneos/usbkey/issues) in this project and detail your thoughts in the description.

## Overview

The system is designed to create a special micro USB drive that contains an encrypted volume to hold 3 SSH keypairs. We create 3 keys (labeled *workstation*, *server*, *secure*) both to maintain a policy of which keys are authorized on what machines, and to reduce the exposure if a single key is compromised. Truthfully, that might be unnecessary as if one key manages to get exposed, the others are likely to be as well (I'm interested in thoughts on this from security professionals).

The USBkeys, while required for remote access of our machines, are not the only authentication factor as we want to increase security through the use of these devices. The second factor would be access to a machine configured to use the USBkey. If a USBkey is lost, the authorized keypairs are removed immediately and we simply create new keys on another micro USB drive. Key authorization and deauthorization is fully manual at this point.

We are currently hardcoding the system to recognize Sandisk Cruzer Fit devices (`Vendor ID: 0x0781`, `Product ID: 0x5571`), but the udev rule can be changed to match any other Vendor/Product combination if you want to try this system out for yourself.

We have full Linux support and partial OS X support at this time. I'd love to add automated support to OS X (using `diskutil`, and a small background process). We still need to finalize how to add Windows support as well.

### Workflow

| Action | Description | Key state |
| --- | --- | --- |
| Run `usb-create` | On any machine, mount the target USB device and format it FAT32. Then switch to that directory and run the setup script. | keypairs are vulnerable |
| Connect USBkey to target workstation | On the target workstation, log in as the target user. Then plug in the USBkey and it will automatically complete the setup process, authorizing the USBkey for use on that workstation and securing the key | secured | 
| Authorize public keys | On any servers or workstations that you want to remotely access, an admin account must now go ahead and authorize the appropriate key from the USBkey. This can also happen before the USBkey is secured, to make it easier to read the publc half of the keypairs. | ready |

*Note*: There is a slight deviation if you want to support OS X, as the OS X target workstation needs to be used after the target Linux workstation before the USBkey is secured.

### Technical Details

* The keys are secured inside of a LUKS encrypted file after creation, and the old unencrypted copies are `shred` (`rm -P` on OS X)
* A randomly generated key is placed in the home account of the target user (`/home/<user>/.usbkey/key`) on the target workstation and it is the only way to decrypt the keypairs
* The `udev` rule (`99-usbkey.rules`) listens for the insertion or removal of a device into the workstation and triggers `usbkey-ctl` as appropriate.
* During device insertion, the drive is mounted, volume is decrypted, and keypairs are added to the `ssh-agent` using the Funtoo Linux project [keychain]:(https://www.funtoo.org/Keychain). Keys are set to expire in 24 hours just in case.
* During device removal, all keys are removed from the running `ssh-agent` process.

### Future Work

* Install script. We need something that will enable easier installation of all the project components (udev rules, keychain support through shell profile, and project executables)
* Full Mac OS X support. We can automate the workflow using `diskutil`. Currently OS X users have to manually run the script to add the keypairs to `ssh-agent` and they time out, rather than disappearing during device removal.
* Window support... Because some people actually use SSH on Windows *gasp* (`pagent` support, or maybe even cygwin or the new Windows 10 SSH support).
* Third party review. We really need a review of the design of this system from a security professional. Please send them this way if you know anyone interested in this.