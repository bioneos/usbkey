#!/bin/local/bash 


(cd ../ && swift build -c release)
cp ../.build/x86_64-apple-macosx10.10/release/UsbkeyCtlTool ../Package/Root/
