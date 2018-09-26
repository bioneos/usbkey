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

//let deviceID = UIDevice.current.identifierForVendor!.uuidString
  // print(deviceID)

//DADisk; disk
//CFDictionary; diskinfo

/*diskinfo = DADiskCopyDescription(disk);
 CFURLRef; fspath = CFDictionaryGetValue(dict,
                kDADiskDescriptionVolumePathKey);
 
 char; buf[MAXPATHLEN];
 if (CFURLGetFileSystemRepresentation(fspath, false, (UInt8 *),buf, sizeof(buf))) {
    printf("Disk %s mounted at %s\n",
        DADiskGetBSDName(disk),
        buf);
 
    /* Print the complete dictionary for debugging. */
    CFShow(diskinfo);
} else {
    /* Something is *really* wrong. */
}
For a complete list of dictionary keys, see the Constants section in DADisk.h Reference.*/



DARegisterDiskAppearedCallback(
    session!,
    nil,
    { (disk, context) in
        if let name = DADiskGetBSDName(disk) {
            let diskinfo = DADiskCopyDescription(disk);
            
            let key = "DADeviceModel" as NSString
            if let rawResult = CFDictionaryGetValue(diskinfo, Unmanaged.passUnretained(key).toOpaque()) {
                let result = Unmanaged<AnyObject>.fromOpaque(rawResult).takeUnretainedValue() as! String
                //result = result as! String
                let a = "Cruzer Fit" as String
                if (result == a) {
                    print(String(cString: name))
                    shell("./hello.swift")
                }
                //print(result)
            }
        }
},
    nil)

DASessionScheduleWithRunLoop(session!, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

RunLoop.main.run()
