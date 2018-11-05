//
//  Created by Chibuzo Nwakama on 1/10/2018.
//

import Darwin
import IOKit
import IOKit.usb
import Foundation
import DiskArbitration
import os.log

/**
 * the IOUSBDector class that is implements to receive and run callback functions depending on event
 */
class IOUSBDetector
{
  // static variable for the identifications for a Sandisk Cruzer Fit usb
  static let USB_VENDOR_ID : Int = 0x0781
  static let USB_PRODUCT_ID : Int = 0x5571
  static let USB_VENDOR_KEY : String = "SanDisk"
  static let USB_PRODUCT_KEY : String = "Cruzer Fit"
  
  // schedules IOService objects/DASession for matching physical notfications/run Callback functions on a thread
  private let queue: DispatchQueue
  
  // use default ports to create a notification object to communication with IOkit
  private let notifyPort: IONotificationPortRef
  
  // notification iterator which holds new removed notification from IOService
  private var removedIterator: io_iterator_t
  
  // session for register events for disk arbitration like disk appearance
  private let session : DASession?
  
  // constructor
  init()
  {
    // sets iterator to no remaining io_object_t
    removedIterator = 0
    
    // Setting up the DASession to detect insertion of usb device
    queue = DispatchQueue.global(qos: DispatchQoS.QoSClass.default) /*(label: "IODetector")*/
    
    // creates session
    session = DASessionCreate(CFAllocatorGetDefault().takeRetainedValue())
    
    // setups the session to capture registered events
    DASessionSetDispatchQueue(session!, queue)
    
    // Setting up IOkit port to detect removal of usb device
    let notifyPort = IONotificationPortCreate(kIOMasterPortDefault)
    self.notifyPort = notifyPort!
    
    //setup the dispatch queue to capture io notifications
    IONotificationPortSetDispatchQueue(notifyPort, queue)
  }
  
  deinit
  {
    // when program is Removed removes all iokit objects
    stopDetection()
  }
  
  /*
   * starts up detections by add matching notifications for insert and removing of the physical usb
   */
  func startDetection() -> Bool
  {
    guard removedIterator == 0 else
    {
      return true
    }
    
    // sets up matching criteria (vendorID & productID) for usb by using a dictionary used for IOKit
    let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
    matchingDict[kUSBVendorID] = NSNumber(value: IOUSBDetector.USB_VENDOR_ID)
    matchingDict[kUSBProductID] = NSNumber(value: IOUSBDetector.USB_PRODUCT_ID)
    
    // match dictionary for usb device insertion of usb model, vendor, and volume used for IOKit
    let matchingDADict : CFDictionary = [kDADiskDescriptionDeviceModelKey as String : IOUSBDetector.USB_PRODUCT_KEY,
      kDADiskDescriptionDeviceVendorKey as String : IOUSBDetector.USB_VENDOR_KEY,
      kDADiskDescriptionVolumeMountableKey as String : 1] as CFDictionary
    
    // a self pointer used as reference for callback function (DA and IOKit callback functions)
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    
    /*
     * Callback Functions
     */
    
    // callback function - DADiskDescriptionChangedCallback function parameter that call usbkeyInsertCtl
    let diskcallback : DADiskDescriptionChangedCallback = {
      (disk, watch, context) in
      let diskDict  = DADiskCopyDescription(disk)
      
      // volume name like disk2s1
      let diskname = String(cString: DADiskGetBSDName(disk)!)
      logger("Newly mounted volume name: %@", "Debug", diskname)
      
      // gets the mounted disk volume path from the list of changed keys array watch
      let volumeArray = watch as Array
      let volumeIndex : CFString = volumeArray[0] as! CFString
      if let dictionary = diskDict as? [NSString: Any]
      {
        if let volumePath = dictionary[volumeIndex] as! URL?
        {
          usbkeyInsertCtl(keyPath: "key", diskPath: volumePath, dadisk: disk)
        }
      }
    }
    
    /*
     * callback functions for removal a specific usb that are calls dispatchEvent
     * with differnt io_iterators and Events when the respectable Notificationss are fired up
     */
    let ioRemoveCallback : IOServiceMatchingCallback? = {
      (userData, iterator) in
      var nextService = IOIteratorNext(iterator)
      while (nextService != 0)
      {
        usbkeyRemoveCtl()
        nextService = IOIteratorNext(iterator)
      }
    };
    
    // Setup the disk arbiration notification for volume path change
    DARegisterDiskDescriptionChangedCallback(session!,matchingDADict,
      kDADiskDescriptionWatchVolumePath.takeRetainedValue() as CFArray, diskcallback, selfPtr)
    
    /*
     * Setting the notifications for removing events
     * Returns a status value responding to if the new Notification Service was
     * added correctly
     */
    let IONotificationStatus = IOServiceAddMatchingNotification(
      notifyPort, kIOTerminatedNotification,
      matchingDict, ioRemoveCallback, selfPtr, &removedIterator
    )
    
    // Checks if there was an error in the configuration of remove notifications
    guard IONotificationStatus == 0 else
    {
      if removedIterator != 0
      {
        IOObjectRelease(removedIterator)
        removedIterator = 0
      }
      logger("Detection failed to start!", "Error")
      logger("IOService remove matching notification setup failed. Status:  %@", "Error", IONotificationStatus)
      return false
    }
    
    // This is required even if nothing was found to "arm" the callback
    // sets io_iterator to a ready io_object_t to be receive for an event
    IOIteratorNext(removedIterator)
    
    // detector starts
    logger("IOService starting detection of usb removal events..", "Info")
    shell("/usr/bin/osascript", args: "-e", "display notification \"Start Detection\" with title \"UsbkeyCtl\"")
    return true
  }
  
  // Release IO service objects
  func stopDetection()
  {
    guard self.removedIterator != 0 else
    {
      return
    }
    IOObjectRelease(self.removedIterator)
    self.removedIterator = 0
    
    logger("Stopping detection for usb removal events.", "Debug")
  }
}

// Helper functions

/*
 * Runs shell commands
 */
@discardableResult
func shell(_ launchPath : String = "/usr/bin/env", stdInput: FileHandle? = nil, args: String...) -> (Int32, String?)
{
  let task = Process()
  let pipe = Pipe()
  
  task.launchPath = launchPath
  task.arguments = args
  task.standardOutput = pipe
  if let input = stdInput {
    task.standardInput = input
  }
  task.launch()
  
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  let output: String? = String(data: data, encoding: String.Encoding.utf8)
  task.waitUntilExit()
  
  return (task.terminationStatus, output)
}

// Control Usbkey Functions

/**
 * Controls usbkey events when usb is removed from the computer
 * Removes rsa keys to ssh
 * Deletes INSERT file in usbkey_root directory
 * Calls Locksreen protocol
 */
func usbkeyRemoveCtl (usbkey_root: String = "usbkey")
{
  let fullUSBRoot : URL
  do
  {
    fullUSBRoot = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil,
                                      create: false).appendingPathComponent(usbkey_root)
  }
  catch
  {
    logger("Directory ~/Library/ can't be found. Cannot finish usb removal actions.", "Error")
    return
  }
  
  // checks if INSERT file exist if not error will occur
  let isPath = FileManager.default.fileExists(atPath: fullUSBRoot.appendingPathComponent("INSERTED").path)
  if (!isPath)
  {
    logger("Can't find file: %@.  Cannot finish usb removal actions.", "Error", fullUSBRoot.appendingPathComponent("INSERTED").path)
  }
  else
  {
    do
    {
      try FileManager.default.removeItem(at: URL(fileURLWithPath: fullUSBRoot.appendingPathComponent("INSERTED").path))
      
      // removes all keys from ssh
      shell(args: "ssh-add", "-D")
      logger("Removed all RSA keys.", "Info")
      
      // lockscreen/logs off
      shell("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", args: "-suspend")
      logger("Locking screen.", "Debug")      
    }
    catch
    {
      // fails if file did exist but suddenly disappears
      logger("INSERTED file located at %@ Dissappeared. Error - %@", "Error", fullUSBRoot.path, errno)
    }
  }
}
/**
 * Controls usbkey events when usb is inserted into the computer
 * Decrypts Image and add rsa keys to ssh
 * Ejects both the image and usb after process is done
 */
func usbkeyInsertCtl(keyPath: String, diskPath : URL, usbkey_root : String = "usbkey/", dadisk: DADisk?)
{
  // where the encrypted image will mounted to when decrypted – naming of image was created prior
  let mountPoint : String = "/Volumes/usbkey/"
  var fullUSBRoot : URL
  do
  {
    fullUSBRoot = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false).appendingPathComponent(usbkey_root)
  }
  catch
  {
    logger("Directory ~/Library/ can't be found. Error - %@", "Error", errno)
    eject(diskPath: diskPath, override: true, dadisk: dadisk)
    return
  }
  
  /*
   * Part of the setup step
   * Currently it will never run because directory will always exist before this program will run
   */
  // checks to see if the directory for the key exist  and if not creates it and check if we need to setup USBKey
  if (!FileManager.default.fileExists(atPath: fullUSBRoot.path))
  {
    logger("USB Key file doesn't exist... Ejecting usb.", "Error")
    eject(fullUSBRoot: fullUSBRoot, diskPath: diskPath, dadisk: dadisk)
    return
  }
  
  // Decrypt the SPARSE image (using the keyfile)
  logger("Decrypting sparse image...", "Info")
  let fileHandle = FileHandle(forReadingAtPath: fullUSBRoot.appendingPathComponent(keyPath).path)
  shell(stdInput: fileHandle, args: "hdiutil", "attach", "-stdinpass", diskPath.path + "/osx.sparseimage")
  
  // adds rsa keys to ssh from the decrypted image
  if (FileManager.default.fileExists(atPath: mountPoint))
  {
    do
    {
      let files = try FileManager.default.contentsOfDirectory(atPath: mountPoint)
      for key in files
      {
        if (key[key.startIndex] != ".")
        {
          shell(args: "ssh-add", "-t", "7200", String(mountPoint + key))
          logger("Adding ssh key %@", "Info", key)
        }
      }
      shell("/usr/bin/osascript", args: "-e", "display notification \"Keys have been added\" with title \"UsbkeyCtl\"")
      
      // Create Insertion hint
      FileManager.default.createFile(atPath: fullUSBRoot.appendingPathComponent("INSERTED").path , contents: nil, attributes: nil)
    }
    catch
    {
      // if directory that contains rsa doesn't exist error will occur
      logger("Dirctory %@ does not exist. Error - %@", "Error", mountPoint, errno)
    }
  }
  else
  {
    logger("Image didn't decrypt correctly/Sparse image could not be found!", "Error")
  }
  
  // Eject SPARSE device
  let (terminationStatus, output) = shell(args: "hdiutil", "eject", mountPoint)
  logger("Eject for mount point %@: %@, Status - %@", "Info", mountPoint, output!, terminationStatus)
  
  // Ejects usbkey
  eject(fullUSBRoot: fullUSBRoot, diskPath: diskPath, dadisk: dadisk)
}

/**
 * Ejects and Unmounts disk object from computer
 */
func eject(fullUSBRoot : URL? = nil, diskPath : URL, override : Bool = false, dadisk: DADisk?)
{
  let isPath = FileManager.default.fileExists(atPath: fullUSBRoot!.appendingPathComponent("EJECT").path)
  if (isPath || override)
  {
    let wholeDisk = DADiskCopyWholeDisk(dadisk!)
    DADiskUnmount(dadisk!, DADiskUnmountOptions(kDADiskUnmountOptionForce), nil, nil)
    DADiskEject(wholeDisk!, DADiskEjectOptions(kDADiskEjectOptionDefault), nil, nil)
    logger("Ejecting USB: %@", "Debug", diskPath.path)
  }
}

/**
 * sents log messages to the console
 */
func logger(_ description: StaticString, _ type: String, _ args: CVarArg...)
{
  if #available(OSX 10.12, *)
  {
    let customLog = OSLog(subsystem: "com.bioneos.usbkey", category: "usbkey")
    let types : [String: OSLogType] = ["Info": .info, "Debug": .debug, "Error": .error]
    os_log(description, log: customLog, type: types[type] ?? .default, args)
  }
  else
  {
     NSLog("\(type)" + " – " + "\(description)", args)
  }
}

/*
 * the driver that will be run or simply the main function
 */
let usbEventDetector = IOUSBDetector()
_ = usbEventDetector.startDetection()

RunLoop.main.run()
