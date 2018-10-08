//
//  notification.swift
//  
//
//  Created by Chibuzo Nwakama on 1/10/2018.
//

import Darwin
import IOKit
import IOKit.usb
import Foundation
import DiskArbitration

/**
 * the IOUSBDector class that is implements to receive and run callback functions depending on event
 */
class IOUSBDetector {
    /*
     *
    */
    enum Event {
        case Inserted
        case Removed
    }
    
    let vendorID: Int
    let productID: Int
    
    
    //asychronous thread to run the anonymous function - callback
    private var callbackQueue: DispatchQueue?
    
    //anonymous function that is used to response to an event from IOkit
    var callback: (( _ detector: IOUSBDetector,  _ event: Event,_ service: io_service_t) -> Void)?
    
    // schedules IOService objects or matching notfications on a sychronous thread
    private let internalQueue: DispatchQueue
    
    //use default ports to create a notification object to communication with IOkit
    private let notifyPort: IONotificationPortRef
    
    
    //notification iterator which holds new removed notification from IOService
    private var removedIterator: io_iterator_t = 0
    
    //thread for DASession
    private let internalQueueDA : DispatchQueue?
    
    private let session : DASession?
    
    var dadisk : DADisk?
    
    
    /*
     * captures from insert and remove events from usb and runs an asynchronous callback function
     */
    private func dispatchEvent (event: Event, iterator: io_iterator_t) {
        // checks all io services available through io iterator
        repeat {
            let nextService = IOIteratorNext(iterator)
            guard nextService != 0 else { break } // there are no more io serices or notfications
            if let cb = self.callback, let q = self.callbackQueue {
                // asynchrous thread to run callback function
                q.async {
                    cb(self, event, nextService) //runs anonymous callback functions
                    IOObjectRelease(nextService) //release iooject after callback function finishes
                }
            } else {
                IOObjectRelease(nextService)
            }
        } while (true)
    }
    
    
    init? ( vendorID: Int, productID: Int ) {
        self.vendorID = vendorID
        self.productID = productID
        
        //setting the DASession
        //
        self.internalQueueDA = DispatchQueue(label: "IODADetector")
        
        self.session = DASessionCreate(CFAllocatorGetDefault().takeRetainedValue())
    
        DASessionSetDispatchQueue(session!, internalQueueDA)
        
        self.internalQueue = DispatchQueue(label: "IODetector")
        
        self.callbackQueue = DispatchQueue.global()
        
        let notifyPort = IONotificationPortCreate(kIOMasterPortDefault)
        guard notifyPort != nil else { return nil }
        
        self.notifyPort = notifyPort!
        IONotificationPortSetDispatchQueue(notifyPort, self.internalQueue) //setup the dispatch queue to capture io notifications
        
        
        
    }
    
    deinit {
        //when program is Removed removes all iokit objects
        self.stopDetection()
    }
    
    /*
     * starts up detections by add matching notifications for insert and removing of the physical usb
     */
    func startDetection ( ) -> Bool {
        guard removedIterator == 0 else { return true }
        
        //sets up matching criteria (vendorID & productID) for usb by using a dictionary
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matchingDict[kUSBVendorID] = NSNumber(value: vendorID)
        matchingDict[kUSBProductID] = NSNumber(value: productID)
        
        
        
        let matchingDADick = [kDADiskDescriptionDeviceModelKey : "Cruzer Fit", kDADiskDescriptionDeviceVendorKey : "SanDisk", kDADiskDescriptionVolumeMountableKey : 1] as CFDictionary
        
        
        //a self pointer used as reference for callback function
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        /*
         * setup the disk arbiration notification
         */
        //DARegisterDiskAppearedCallback
        //DARegisterDiskMountApprovalCallback
        DARegisterDiskAppearedCallback(
            session!,
            matchingDADick,
            { (disk, context) in
                if DADiskGetBSDName(disk) != nil {
                    DispatchQueue.global(qos: DispatchQoS.QoSClass.background).asyncAfter(deadline: .now() + 2){
                        usbkey_ctl(x: IOUSBDetector.Event.Inserted, path: "/Library/usbkey/key", disk: disk)
                    }
                    
                }
        },
            selfPtr)
        
        
        /*
         * stores callback matching functions for insert and remove that are calls dispatchEvent
         * with differnt io_iterators and Events when the respectable notifcations are fired up
         */
        
        let termCallback: IOServiceMatchingCallback = {
            (userData, iterator) in
            let detector = Unmanaged<IOUSBDetector>
                .fromOpaque(userData!).takeUnretainedValue()
            detector.dispatchEvent(
                event: .Removed, iterator: iterator
            )
        };
        
        
        
        /*
         * Setting the notifications for add and removing events
         * returns a status value responding to if the new Notification Service was
         * added correctly
         */
        let removeAddNotificationStatus = IOServiceAddMatchingNotification(
            self.notifyPort, kIOTerminatedNotification,
            matchingDict, termCallback, selfPtr, &self.removedIterator
        )
        
        
        //checks if there was an error in the configuration of add and remove notifications
        guard removeAddNotificationStatus == 0 else {
            if self.removedIterator != 0 {
                IOObjectRelease(self.removedIterator)
                self.removedIterator = 0
            }
            return false
        }
        
        // This is required even if nothing was found to "arm" the callback
        self.dispatchEvent(event: .Removed, iterator: self.removedIterator)
        
        return true
    }
    
    //Release IO service objects
    func stopDetection ( ) {
        guard self.removedIterator != 0 else { return }
        IOObjectRelease(self.removedIterator)
        self.removedIterator = 0
    }
    
}

/*
 * Helper functions
 */

//runs shell commands
@discardableResult
func shell(_ args: String... , launchPath : String = "/usr/bin/env") -> (Int32, String?) {
    
    let task = Process()
    let pipe = Pipe()
    task.launchPath = launchPath
    task.arguments = args
    task.standardOutput = pipe
    task.launch()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output: String? = String(data: data, encoding: String.Encoding.utf8)
    task.waitUntilExit()
    return (task.terminationStatus, output)
}

//returns if file/directory and determines which one it is
func checkFileDirectoryExist(fullPath: String) -> (Bool, Bool) {
    //checks if a directory or file exist
    let fileManager = FileManager.default
    var isDir : ObjCBool = false
    if fileManager.fileExists(atPath: fullPath, isDirectory:&isDir) {
        if isDir.boolValue {
            // file exists and is a directory
            return (true, false)
        } else {
            // file exists and is not a directory
            return (false, true)
        }
    } else {
        // neither exist
        return (false, false)
    }
}

func usbkey_ctl(x: IOUSBDetector.Event, path: String, disk : DADisk?){
    /*genetics paths needed*/
    let usbkey_root = "/Library/usbkey/"
    let mount_point : String = "/Volumes/usbkey/"
    let fileManager = FileManager.default
    let homeDir = fileManager.homeDirectoryForCurrentUser
    
    /*checks to see '/Library/usbkey/' exist and if not creates it*/
    var (directory, _) = checkFileDirectoryExist(fullPath: homeDir.path + usbkey_root)
    if (!directory){
        do {
            try fileManager.createDirectory(atPath: homeDir.path + usbkey_root, withIntermediateDirectories: true)
        }
        catch {
            return
        }
    }
    
    
    
    //chooses a case base on what event was passed in the function
    switch x {
        case IOUSBDetector.Event.Inserted:
            let diskDict  = DADiskCopyDescription(disk!)
            var newPath = "/Volumes/"
            //print (diskDict)
            if let name = (diskDict as! NSDictionary)[kDADiskDescriptionVolumeNameKey] as! String? {
                newPath = "/Volumes/" + name + "/"
            }
            
            //check if we need to setup USBKey
            //TODO add a log functionality
            
            //Decrypt the SPARSE image (using the keyfile)
            decryptImage(path: homeDir.path + path, sparsePath: newPath)
            
            
            //adds rsa keys to ssh from the decrypted image
            (directory, _) = checkFileDirectoryExist(fullPath: mount_point)
            if (directory){
                do {
                    let files = try fileManager.contentsOfDirectory(atPath: mount_point)
                for key in files{
                    if (key[key.startIndex] != "."){
                        shell("ssh-add", "-t", "7200", String(mount_point + key))
                    }
                }
                    let (_, output) = shell("ssh-add", "-l")
                    print ("\n" + output!)
                } catch {
                    return
                }
            }

            //Eject SPARSE device
            shell("hdiutil", "eject", mount_point)
              
            //Create Insertion hint
            fileManager.createFile(atPath: homeDir.path + usbkey_root + "INSERTED", contents: nil, attributes: nil)
            
        
            shell("diskutil", "eject", newPath)
            print ("eject")
        
    case IOUSBDetector.Event.Removed:
        let (_, file) = checkFileDirectoryExist(fullPath: homeDir.path + usbkey_root + "INSERTED")
        if (!file){
            return
        }
        else{
            do {
                try fileManager.removeItem(at: URL(fileURLWithPath: homeDir.path + usbkey_root + "INSERTED"))
            }
            catch {
                return
            }
        }
        //shell("pmset", "displaysleepnow")
        shell("-suspend", launchPath: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
        shell("ssh-add", "-D")
        
        
        
    }
}

func decryptImage(path: String, sparsePath: String) -> Void {
    let url = URL(fileURLWithPath: path)
    let urlDevice = URL(fileURLWithPath: sparsePath)
    let dir = url.deletingLastPathComponent()
    let last = url.lastPathComponent
    let fileUrl = dir.appendingPathComponent(last)
    do {
        let key = try String(contentsOf: fileUrl, encoding: .utf8)
        let newKey = key.replacingOccurrences(of: "\n", with: "", options: .literal, range: nil)
        hdiutilAttach(key: ["printf", newKey], args: ["hdiutil", "attach", "-stdinpass", urlDevice.path + "/osx.sparseimage"])
    }
    catch{
        print ("Fail")
        return
    }
    
}
func hdiutilAttach(key: [String], args: [String]) -> Void {
    let pipe = Pipe()
    
    let printf = Process()
    printf.launchPath = "/usr/bin/env"
    printf.arguments = key
    printf.standardOutput = pipe
    
    let hdiutil = Process()
    hdiutil.launchPath = "/usr/bin/env"
    hdiutil.arguments = args
    hdiutil.standardInput = pipe
    
    let out = Pipe()
    hdiutil.standardOutput = out
    
    printf.launch()
    hdiutil.launch()
    
    
    
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let output = NSString(data: data, encoding: String.Encoding.utf8.rawValue)
    hdiutil.waitUntilExit()
    print(output ?? "no output")
}





/*
 * the driver that will be run or simply the main function
 */
let test = IOUSBDetector(vendorID: 0x0781, productID: 0x5571)
_ = test?.startDetection()

test?.callback = {
    (detector, event, service) in
    usbkey_ctl(x: event, path: "/Library/usbkey/key", disk: test?.dadisk)
};
 print ("Start")

//while true {test?.run()}
while true {sleep(1)}

