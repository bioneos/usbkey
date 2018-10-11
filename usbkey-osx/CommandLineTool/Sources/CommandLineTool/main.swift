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
    
    // how usb device is identified
    let vendorID: Int
    let productID: Int
    
    private let internalQueueFS : DispatchQueue?
    
    //asychronous thread (1) to run the anonymous function - callback
    private var callbackQueue: DispatchQueue?
    
    //anonymous function that is used to response to an event from IOkit
    private let callback: (( _ detector: IOUSBDetector, _ service: io_service_t) -> Void)?
    
    // schedules IOService objects or matching notfications on a sychronous thread (2)
    private let internalQueue: DispatchQueue
    
    //use default ports to create a notification object to communication with IOkit
    private let notifyPort: IONotificationPortRef
    
    //notification iterator which holds new removed notification from IOService
    private var removedIterator: io_iterator_t = 0
    
    //thread (3) for DASession
    private let internalQueueDA : DispatchQueue?
    
    //session for register events for disk arbitration like disk appearance
    private let session : DASession?
    
    // FSEventStream object that used receive FS Events
    var fsEventStream : FSEventStreamRef?
    
    // Stores the file path of inserted disk
    var diskPathDA : String?
    
    // FSEventStream callback function fired when FS Event occurs
    var fsEventCallback : FSEventStreamCallback?
    
    // DA callback function fired when DA Appeared notification occurs
    var diskcallback : DADiskAppearedCallback?
    
    // IOService callback function fired when a specific usb is physically removed from IO ports occurs
    var ioRemoveCallback : IOServiceMatchingCallback?
    
    
    /*
     * captures from insert and remove events from usb and runs an asynchronous callback function
     */
    private func dispatchEvent (iterator: io_iterator_t) {
        // checks all io services available through io iterator
        repeat {
            let nextService = IOIteratorNext(iterator)
            guard nextService != 0 else { break } // there are no more io serices or notfications
            if let cb = self.callback, let q = self.callbackQueue {
                // asynchrous thread to run callback function
                q.async {
                    cb(self, nextService) // runs anonymous callback functions
                    IOObjectRelease(nextService) // release iooject after callback function finishes
                }
            } else {
                IOObjectRelease(nextService)
            }
        } while (true)
    }
    
    
    init? ( vendorID: Int, productID: Int ) {
        self.vendorID = vendorID
        self.productID = productID
        
        self.internalQueueFS = DispatchQueue.global(qos: DispatchQoS.QoSClass.background)
        
        /*
         * Setting up the DASession to detect insertion of usb device
         */
        self.internalQueueDA = DispatchQueue(label: "IODADetector")
        
        self.session = DASessionCreate(CFAllocatorGetDefault().takeRetainedValue())
        
        DASessionSetDispatchQueue(session!, internalQueueDA) //setups the session to capture registered events
        
        
        /*
         * Setting up IOkit port to detect removal of usb device
         */
        self.internalQueue = DispatchQueue(label: "IODetector")
        
        self.callbackQueue = DispatchQueue.global()
        
        let notifyPort = IONotificationPortCreate(kIOMasterPortDefault)
        guard notifyPort != nil else { return nil } //checking for errors
        
        self.notifyPort = notifyPort!
        IONotificationPortSetDispatchQueue(notifyPort, self.internalQueue) //setup the dispatch queue to capture io notifications
        
        // the callback usbkey removal function initialization
        self.callback = {
            (detector, service) in
            usbkey_removeCtl()
        }
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
        
        // sets up matching criteria (vendorID & productID) for usb by using a dictionary used for IOKit
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matchingDict[kUSBVendorID] = NSNumber(value: vendorID)
        matchingDict[kUSBProductID] = NSNumber(value: productID)
        
        // match dictionary for usb device insertion of usb model, vendor, and volume used for IOKit
        let matchingDADick : CFDictionary = [kDADiskDescriptionDeviceModelKey as String : "Cruzer Fit",
                    kDADiskDescriptionDeviceVendorKey as String : "SanDisk", kDADiskDescriptionVolumeMountableKey as String : 1] as CFDictionary
        
        // a self pointer used as reference for callback function (DA and IOKit callback functions)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        /*
         * Callback Functions
         */
        
        // callback functions for FSEventStream that stops FSEventStream and removes it FSEventStream DispatchQueue Thread
        self.fsEventCallback =
            { (streamRef, clientCallBack, numEvents, eventPaths, eventFlags, eventIds) in
                let detector : IOUSBDetector = unsafeBitCast(clientCallBack, to: IOUSBDetector.self)
                let usbPath = detector.diskPathDA
                usbkey_InsertCtl(keyPath: "key", diskPath: usbPath)
                FSEventStreamStop(streamRef)
                FSEventStreamInvalidate(streamRef)
                
        }
        
        // callback function - DiskAppearedCallback function parameter that is used to create and set FSEventStream
        self.diskcallback =
        { (disk, context) in
            let detector = Unmanaged<IOUSBDetector>.fromOpaque(context!).takeUnretainedValue()
            let diskDict  = DADiskCopyDescription(disk)
            var newPath = "/Volumes/"
            let cfarray = [newPath] as CFArray
            if let name = (diskDict as! NSDictionary)[kDADiskDescriptionVolumeNameKey] as! String? {
                // creates FSEventStream Notifcation variable
                newPath = "/Volumes/" + name + "/"
                detector.diskPathDA = newPath // the path to the mount usbkey
                var selfPtrFS : FSEventStreamContext = FSEventStreamContext(version: 0, info: context, retain: nil, release: nil, copyDescription: nil)
                
                // Setup the FSEventStream
                detector.fsEventStream = FSEventStreamCreate(kCFAllocatorDefault, detector.fsEventCallback!, &selfPtrFS, cfarray as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0, FSEventStreamCreateFlags(kFSEventStreamEventFlagNone))!
                FSEventStreamSetDispatchQueue(detector.fsEventStream!, detector.internalQueueFS) // sets thread
                FSEventStreamStart(detector.fsEventStream!) // starts FSEvent Notifcations
            }
        }
        
        /*
         * callback functions for removal a specific usb that are calls dispatchEvent
         * with differnt io_iterators and Events when the respectable notifcations are fired up
         */
        self.ioRemoveCallback = {
            (userData, iterator) in
            let detector = Unmanaged<IOUSBDetector>
                .fromOpaque(userData!).takeUnretainedValue()
            detector.dispatchEvent(iterator: iterator)
        };
        
        // Setup the disk arbiration notification
        DARegisterDiskAppearedCallback(session!,matchingDADick, self.diskcallback!, selfPtr)
        
        /*
         * Setting the notifications for removing events
         * Returns a status value responding to if the new Notification Service was
         * added correctly
         */
        let removeAddNotificationStatus = IOServiceAddMatchingNotification(
            self.notifyPort, kIOTerminatedNotification,
            matchingDict, self.ioRemoveCallback, selfPtr, &self.removedIterator
        )
        
        // Checks if there was an error in the configuration of remove notifications
        guard removeAddNotificationStatus == 0 else {
            if self.removedIterator != 0 {
                IOObjectRelease(self.removedIterator)
                self.removedIterator = 0
            }
            return false
        }
        
        // This is required even if nothing was found to "arm" the callback
        self.dispatchEvent(iterator: self.removedIterator)
        
        return true
    }
    
    // Release IO service objects
    func stopDetection () {
        guard self.removedIterator != 0 else { return }
        IOObjectRelease(self.removedIterator)
        self.removedIterator = 0
    }
    
}


//Helper functions

/*
 * Runs shell commands
 */
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

/*
 * Runs a two away command pipeline shell commands
 */
func pipeline(args1: [String], args2: [String]) -> Void {
    let pipe = Pipe()
    
    let cmd1 = Process()
    cmd1.launchPath = "/usr/bin/env"
    cmd1.arguments = args1
    cmd1.standardOutput = pipe
    
    let cmd2 = Process()
    cmd2.launchPath = "/usr/bin/env"
    cmd2.arguments = args2
    cmd2.standardInput = pipe
    
    let out = Pipe()
    cmd2.standardOutput = out
    
    cmd1.launch()
    cmd2.launch()
    
    let data = out.fileHandleForReading.readDataToEndOfFile()
    let output = NSString(data: data, encoding: String.Encoding.utf8.rawValue)
    cmd2.waitUntilExit()
    
    // add log
    print ("Output of Pipeline with paramters - ")
    print ("args1:")
    print (args1)
    print("args2:")
    print (args2)
    print (output ?? "No Output")
}

/*
 * Decrypts and attach image to disk
 */
func decryptImage(path: URL, sparsePath: String) -> Void {
    let urlDevice = URL(fileURLWithPath: sparsePath)
    do {
        // encodes characters in key file
        let key = try String(contentsOf: path, encoding: .utf8)
        let newKey = key.replacingOccurrences(of: "\n", with: "", options: .literal, range: nil)
        
        // runs pipeline printf $newKey | hdiutil attach -stdinpass "$urlDevice.path"/osx.spareimage
        pipeline(args1: ["printf", newKey], args2: ["hdiutil", "attach", "-stdinpass", urlDevice.path + "/osx.sparseimage"])
    }
    catch{
        print ("Error - Encoding characters in key failed") // add log
        return
    }
}

/*
 * Returns if file/directory and determines which one it is
 */
func checkFileDirectoryExist(fullPath: String) -> (Bool, Bool) {
    // checks if a directory or file exist
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



//Control Usbkey Functions

/**
 * Controls usbkey events when usb is removed from the computer
 * Removes rsa keys to ssh
 * Deletes INSERT file in usbkey_root directory
 * Calls Locksreen protocol
 */
func usbkey_removeCtl (usbkey_root: String = "usbkey"){
    
    let fileManager : FileManager = FileManager.default
    var libraryDirectory : URL
    let fullUSBRoot : URL
    do {
        libraryDirectory = try fileManager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        fullUSBRoot = libraryDirectory.appendingPathComponent(usbkey_root)
    }
    catch {
        return
    }
        
    
    
    // checks if INSERT file exist if not error will occur
    let (_, file) = checkFileDirectoryExist(fullPath: fullUSBRoot.appendingPathComponent("INSERTED").path )
    if (!file){
        return
    }
    else{
        do {
            try fileManager.removeItem(at: URL(fileURLWithPath: fullUSBRoot.appendingPathComponent("INSERTED").path))
        }
        catch {
            // fails if file did exist but suddenly disappears
            print ("Error - INSERTED file located at " + fullUSBRoot.path + " Disappeared") //add log
            return
        }
    }
    // goes to sleep mode
    // shell("pmset", "displaysleepnow")
    
    // lockscreen
    shell("-suspend", launchPath: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
    print ("Lockscreen") //add log
    
    // removes all keys from ssh
    shell("ssh-add", "-D")
    print ("ssh-add -D: Removed all RSA keys") //add logs
}
/**
 * Controls usbkey events when usb is inserted into the computer
 * Decrypts Image and add rsa keys to ssh
 * Ejects both the image and usb after process is done
 */
func usbkey_InsertCtl(keyPath: String, diskPath : String?, usbkey_root : String = "usbkey/"){
    // genetics paths needed for insert
    let mount_point : String = "/Volumes/usbkey/" //where the encrypted image will mounted to when decrypted
    let fileManager = FileManager.default
    var libraryDirectory : URL
    var fullUSBRoot : URL
    do {
        libraryDirectory = try fileManager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        fullUSBRoot = libraryDirectory.appendingPathComponent(usbkey_root)
    }
    catch {
        return
    }
    
    /*
     * Part of the setup step
     * Currently it will never run cause directory will always exist before this program will run
     */
    // checks to see if the directory for the key exist  and if not creates it and check if we need to setup USBKey
    var (directory, _) = checkFileDirectoryExist(fullPath: fullUSBRoot.path)
    if (!directory){
        do {
            try fileManager.createDirectory(atPath: fullUSBRoot.path, withIntermediateDirectories: true)
        }
        catch {
            // TODO add logs and display saying that directory keyPath couldn't be created
            print ("Directory for" + keyPath + " couldn't be created") //add log and display
            return
        }
    }
    
            
    
    // TODO add a log functionality
            
    // Decrypt the SPARSE image (using the keyfile)
    print ("Decrypting Sparse Image") //add log
    let path = fullUSBRoot.appendingPathComponent(keyPath)
    decryptImage(path: path , sparsePath: diskPath!)
            
            
    // adds rsa keys to ssh from the decrypted image
    (directory, _) = checkFileDirectoryExist(fullPath: mount_point)
    if (directory){
        do {
            let files = try fileManager.contentsOfDirectory(atPath: mount_point)
            for key in files{
                if (key[key.startIndex] != "."){
                    shell("ssh-add", "-t", "7200", String(mount_point + key)) //adds rsa key to ssh
                    print ("Add key " + key) // add log
                }
            }
            let (_, output) = shell("ssh-add", "-l") // shows current ssh keys in user ssh
            print ("ssh-add -l: " + output!) // add log
        } catch {
            // if directory that contains rsa doesn't exist error will occur
            print ("Error - Dirctory suddenly disppeared") // add log and display
            return
        }
    }
    else {
        print ("Image didn't decrypt correct/Image doesn't exist") // add log
    }
    
    // Eject SPARSE device
    shell("hdiutil", "eject", mount_point)
    print ("Eject Encrypted Image " + mount_point) // change to log
    
    // Create Insertion hint
    fileManager.createFile(atPath: fullUSBRoot.appendingPathComponent("INSERTED").path , contents: nil, attributes: nil)
    
    // Ejects usbkey
    // TODO add condition to check for EJECT file to eject
    let (_, file) = checkFileDirectoryExist(fullPath: fullUSBRoot.appendingPathComponent("EJECT").path)
    if (file){
        shell("diskutil", "eject", diskPath!)
        print ("eject") //change to log
    }
    //shell("diskutil", "eject", diskPath!)
    //print ("Eject " + diskPath!) // change to log
}




/*
 * the driver that will be run or simply the main function
 */
let usbEventDetector = IOUSBDetector(vendorID: 0x0781, productID: 0x5571)
_ = usbEventDetector?.startDetection()


print ("Start")

RunLoop.main.run()

