#!/bin/bash

# Constants
install_path='/usr/local/bin/'
identifer='com.bioneos.usbkeyctl'
name='USBKeyCtl.pkg'
version='1.0'
scripts='USBKeyCtl/'
root='Root/'

# Builds a package locally 
pkgbuild --root $root --ownership preserve --install-location $install_path --scripts $scripts --identifier $identifer --version $version $name
