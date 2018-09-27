#!/usr/bin/env swift



import Foundation
import DiskArbitration

let session = DASessionCreate(CFAllocatorGetDefault().takeRetainedValue())

@discardableResult
func shell(_ args: String...) -> Int32 {
    let task = Process()
    task.launchPath = "/usr/bin/env"
    task.arguments = args
    task.launch()
    task.waitUntilExit()
    return task.terminationStatus
}




DARegisterDiskAppearedCallback(
    session!,
    nil,
    { (disk, context) in
        if let name = DADiskGetBSDName(disk) {
            let diskinfo = DADiskCopyDescription(disk);
            
            let key = "DADeviceModel" as NSString
            if let rawResult = CFDictionaryGetValue(diskinfo, Unmanaged.passUnretained(key).toOpaque()) {
                let result = Unmanaged<AnyObject>.fromOpaque(rawResult).takeUnretainedValue() as! String
                let a = "Cruzer Fit" as String
                if (result == a) {
                    print(String(cString: name))
                    shell("ls")
                }
            }
        }
},
    nil)

DASessionScheduleWithRunLoop(session!, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

RunLoop.main.run()
