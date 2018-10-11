//
//  main.swift
//  USBkeyOSX
//
//  Created by Chibuzo Nwakama on 3/10/2018.
//  Copyright © 2018 Chibuzo Nwakama. All rights reserved.
//

import Foundation
let usbEventDetector = IOUSBDetector(vendorID: 0x0781, productID: 0x5571)
_ = usbEventDetector?.startDetection()


print ("Start")

RunLoop.main.run()
//while true {sleep(1)}



