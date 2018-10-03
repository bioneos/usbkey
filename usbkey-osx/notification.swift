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
import CommonCrypto

/**
 * the IOUSBDector class that is implements to receive and run callback functions depending on event 
 */
class IOUSBDetector {
    enum Event {
        case Matched
        case Terminated
    }
    
    let vendorID: Int
    let productID: Int
    
    //used asychronous queue to run the anonymous function - callback
    var callbackQueue: DispatchQueue?
    
    //anonymous function that is used to response to an event from IOkit
    var callback: (( _ detector: IOUSBDetector,  _ event: Event,_ service: io_service_t) -> Void
    )?
    
    
    private
    let internalQueue: DispatchQueue
    
    private
    let notifyPort: IONotificationPortRef
    
    private
    var matchedIterator: io_iterator_t = 0
    
    private
    var terminatedIterator: io_iterator_t = 0
    
    
    /*captures add and removing events from usb asynchronously*/
    private
    func dispatchEvent (event: Event, iterator: io_iterator_t) {
        repeat {
            let nextService = IOIteratorNext(iterator)
            guard nextService != 0 else { break }
            if let cb = self.callback, let q = self.callbackQueue {
                q.async {
                    cb(self, event, nextService) //runs anonymous functions
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
        self.internalQueue = DispatchQueue(label: "IODetector")
        
        //use default ports to create a notification object to communication with IOkit
        let notifyPort = IONotificationPortCreate(kIOMasterPortDefault)
        guard notifyPort != nil else { return nil }
        
        self.notifyPort = notifyPort!
        IONotificationPortSetDispatchQueue(notifyPort, self.internalQueue)
    }
    
    deinit {
        //when program is terminated removes all iokit objects
        self.stopDetection()
    }
    
    
    func startDetection ( ) -> Bool {
        guard matchedIterator == 0 else { return true }
        
        //sets up match directory for usb
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matchingDict[kUSBVendorID] = NSNumber(value: vendorID)
        matchingDict[kUSBProductID] = NSNumber(value: productID)
        
        //*the callback functions that are called when respectable notifcations are fired up*/
        let matchCallback: IOServiceMatchingCallback = {
            (userData, iterator) in
            let detector = Unmanaged<IOUSBDetector>
                .fromOpaque(userData!).takeUnretainedValue()
            detector.dispatchEvent(
                event: .Matched, iterator: iterator
            )
        };
        let termCallback: IOServiceMatchingCallback = {
            (userData, iterator) in
            let detector = Unmanaged<IOUSBDetector>
                .fromOpaque(userData!).takeUnretainedValue()
            detector.dispatchEvent(
                event: .Terminated, iterator: iterator
            )
        };
        
        
        //a self pointer used as reference for callback function
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        
        
        /*Setting the notifications for add and removing usb*/
        let addMatchError = IOServiceAddMatchingNotification(
            self.notifyPort, kIOFirstMatchNotification,
            matchingDict, matchCallback, selfPtr, &self.matchedIterator
        )
        let addTermError = IOServiceAddMatchingNotification(
            self.notifyPort, kIOTerminatedNotification,
            matchingDict, termCallback, selfPtr, &self.terminatedIterator
        )
        
        
        //checks if there was an error in the configuration of add and remove notifications
        guard addMatchError == 0 && addTermError == 0 else {
            if self.matchedIterator != 0 {
                IOObjectRelease(self.matchedIterator)
                self.matchedIterator = 0
            }
            if self.terminatedIterator != 0 {
                IOObjectRelease(self.terminatedIterator)
                self.terminatedIterator = 0
            }
            return false
        }
        
        // This is required even if nothing was found to "arm" the callback
        self.dispatchEvent(event: .Matched, iterator: self.matchedIterator)
        self.dispatchEvent(event: .Terminated, iterator: self.terminatedIterator)
        
        return true
    }
    
    //Release IO service objects
    func stopDetection ( ) {
        guard self.matchedIterator != 0 else { return }
        IOObjectRelease(self.matchedIterator)
        IOObjectRelease(self.terminatedIterator)
        self.matchedIterator = 0
        self.terminatedIterator = 0
    }
}


//runs shell commands
@discardableResult
func shell(_ args: String...) -> (Int32, String?) {
    
    let task = Process()
    let pipe = Pipe()
    task.launchPath = "/usr/bin/env"
    task.arguments = args
    task.standardOutput = pipe
    task.launch()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output: String? = String(data: data, encoding: String.Encoding.utf8)
    task.waitUntilExit()
    //task.terminationStatus
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
func usbkey_ctl(x: IOUSBDetector.Event){
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
        case IOUSBDetector.Event.Matched:
            //check if we need to setup USBKey
            //TODO add a log functionality
            
            //Decrypt the SPARSE image (using the keyfile)
            shell("./decrypt.sh")
            
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
                    /*let (_, output) = shell("ssh-add", "-l")
                    print ("\n" + output!)*/
                } catch {
                    return
                }
            }

            //Eject SPARSE device
            shell("hdiutil", "eject", mount_point)
              
            //Create Insertion hint
            do {
                try fileManager.createDirectory(atPath: homeDir.path + usbkey_root + "INSERTED", withIntermediateDirectories: true)
            }
            catch {
                return
        }
            //Eject USBKey device
            shell("diskutil", "eject", "disk2")
        
    case IOUSBDetector.Event.Terminated: break
        
        
        
    }
}



/*
 * the driver that will be run or simply the main function
 */

let test = IOUSBDetector(vendorID: 0x0781, productID: 0x5571)
test?.callbackQueue = DispatchQueue.global()
test?.callback = {
    (detector, event, service) in
    usbkey_ctl(x: event)
    print (service)
};

_ = test?.startDetection()


while true {sleep(1)}
