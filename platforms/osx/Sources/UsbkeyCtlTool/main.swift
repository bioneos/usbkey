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
  static let SANDISKID : Int = 0x0781
  static let CRUZERFITID : Int = 0x5571
  
  // how usb device is identified
  private let vendorID: Int
  private let productID: Int
  
  // schedules IOService objects/DASession for matching physical notfications/run Callback functions on a thread
  private let queue: DispatchQueue
  
  // use default ports to create a notification object to communication with IOkit
  private let notifyPort: IONotificationPortRef
  
  // notification iterator which holds new removed notification from IOService
  private var removedIterator: io_iterator_t
  
  // session for register events for disk arbitration like disk appearance
  private let session : DASession?
  
  // constructor
  init? ( vendorID: Int, productID: Int )
  {
    self.vendorID = vendorID
    self.productID = productID
    
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
    guard notifyPort != nil else
    {
      // checking for errors
      return nil
    }
    self.notifyPort = notifyPort!
    
    //setup the dispatch queue to capture io notifications
    IONotificationPortSetDispatchQueue(notifyPort, queue)
  }
  
  deinit
  {
    //when program is Removed removes all iokit objects
    stopDetection()
  }
  
  /*
   * starts up detections by add matching notifications for insert and removing of the physical usb
   */
  func startDetection () -> Bool
  {
    guard removedIterator == 0 else
    {
      return true
    }
    
    // sets up matching criteria (vendorID & productID) for usb by using a dictionary used for IOKit
    let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
    matchingDict[kUSBVendorID] = NSNumber(value: vendorID)
    matchingDict[kUSBProductID] = NSNumber(value: productID)
    
    // match dictionary for usb device insertion of usb model, vendor, and volume used for IOKit
    let matchingDADict : CFDictionary = [kDADiskDescriptionDeviceModelKey as String : "Cruzer Fit",
                                         kDADiskDescriptionDeviceVendorKey as String : "SanDisk", kDADiskDescriptionVolumeMountableKey as String : 1] as CFDictionary
    
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
      logger("Name of Volume %@", "Info", diskname)
      
      // gets the mounted disk volume path from the list of changed keys array watch
      let volumeArray = watch as Array
      let volumeIndex : CFString = volumeArray[0] as! CFString
      if let dictionary = diskDict as? [NSString: Any]
      {
        if let volumePath = dictionary[volumeIndex] as! URL?
        {
          usbkeyInsertCtl(keyPath: "key", diskPath: volumePath.path, dadisk: disk)
        }
      }
    }
    
    /*
     * callback functions for removal a specific usb that are calls dispatchEvent
     * with differnt io_iterators and Events when the respectable Notificationss are fired up
     */
    let ioRemoveCallback : IOServiceMatchingCallback? = {
      (userData, iterator) in
      repeat
      {
        let nextService = IOIteratorNext(iterator)
        guard nextService != 0 else
        {
          break
        }
        usbkeyRemoveCtl()
      } while (true)
      
      
    };
    
    // Setup the disk arbiration notification for volume path change
    DARegisterDiskDescriptionChangedCallback(session!,matchingDADict,
      kDADiskDescriptionWatchVolumePath.takeRetainedValue() as CFArray, diskcallback, selfPtr)
    
    /*
     * Setting the notifications for removing events
     * Returns a status value responding to if the new Notification Service was
     * added correctly
     */
    let removeAddNotificationStatus = IOServiceAddMatchingNotification(
      notifyPort, kIOTerminatedNotification,
      matchingDict, ioRemoveCallback, selfPtr, &removedIterator
    )
    
    // Checks if there was an error in the configuration of remove notifications
    guard removeAddNotificationStatus == 0 else
    {
      if removedIterator != 0
      {
        IOObjectRelease(removedIterator)
        removedIterator = 0
      }
      logger("Detection Fails to Start", "Info")
      logger("IOService Remove Matching Notification Setup Failed to Setup Error %@", "Error", removeAddNotificationStatus)
      
      return false
    }
    
    // This is required even if nothing was found to "arm" the callback
    // sets io_iterator to a ready io_object_t to be receive for an event
    IOIteratorNext(removedIterator)
    
    if #available(OSX 10.12, *)
    {
      os_log("Start Detection", log: OSLog.default, type: .info)
    }
    else
    {
      // Fallback on earlier versions
      NSLog("Start Detection")
    }
    let appleScript = "display notification \"Detection has Started\" with title \"UsbkeyCtl\""
    var error: NSDictionary?
    if let scriptAction : NSAppleScript = NSAppleScript(source: appleScript)
    {
      scriptAction.executeAndReturnError(&error)
      if let e = error
      {
        logger("%@", "Error", e)
      }
    }
    
    return true
  }
  
  // Release IO service objects
  func stopDetection ()
  {
    guard self.removedIterator != 0 else
    {
      return
    }
    IOObjectRelease(self.removedIterator)
    self.removedIterator = 0
    
    logger("Stop Detection", "Info")
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
/*
 * Returns if file/directory and determines which one it is
 */
func checkFileDirectoryExist(fullPath: String) -> (Bool, Bool)
{
  // checks if a directory or file exist
  let fileManager = FileManager.default
  var isDir : ObjCBool = false
  if fileManager.fileExists(atPath: fullPath, isDirectory:&isDir)
  {
    if isDir.boolValue
    {
      // file exists and is a directory
      return (true, false)
    }
    else
    {
      // file exists and is not a directory
      return (false, true)
    }
  }
  else
  {
    // neither exist
    return (false, false)
  }
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
  
  let fileManager : FileManager = FileManager.default
  var libraryDirectory : URL
  let fullUSBRoot : URL
  do
  {
    libraryDirectory = try fileManager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    fullUSBRoot = libraryDirectory.appendingPathComponent(usbkey_root)
  }
  catch
  {
    logger("Directory ~/Library/ can't be find. Error - %@", "Error")
    return
  }
  
  
  
  // checks if INSERT file exist if not error will occur
  let (_, file) = checkFileDirectoryExist(fullPath: fullUSBRoot.appendingPathComponent("INSERTED").path )
  if (!file)
  {
    logger("Can't find file path %@", "Info", fullUSBRoot.appendingPathComponent("INSERTED").path)
    return
  }
  else
  {
    do
    {
      try fileManager.removeItem(at: URL(fileURLWithPath: fullUSBRoot.appendingPathComponent("INSERTED").path))
    }
    catch
    {
      // fails if file did exist but suddenly disappears
      logger("INSERTED file located at %@ Dissappeared. Error - %@", "Error", fullUSBRoot.path, errno)
      return
    }
  }
  
  // goes to sleep mode
  // shell("pmset", "displaysleepnow")
  
  // lockscreen/logs off
  shell("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", args: "-suspend")
  logger("Lockscreen", "Info")
  
  // removes all keys from ssh
  shell(args: "ssh-add", "-D")
  logger("ssh-add -D: Removed all RSA keys", "Info")
}
/**
 * Controls usbkey events when usb is inserted into the computer
 * Decrypts Image and add rsa keys to ssh
 * Ejects both the image and usb after process is done
 */
func usbkeyInsertCtl(keyPath: String, diskPath : String?, usbkey_root : String = "usbkey/", dadisk: DADisk?)
{
  // genetics paths needed for insert
  let mountPoint : String = "/Volumes/usbkey/" //where the encrypted image will mounted to when decrypted
  let fileManager = FileManager.default
  var libraryDirectory : URL
  var fullUSBRoot : URL
  do
  {
    libraryDirectory = try fileManager.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    fullUSBRoot = libraryDirectory.appendingPathComponent(usbkey_root)
  }
  catch
  {
    logger("Directory ~/Library/ can't be find. Error - %@", "Error", errno)
    eject(diskPath: diskPath!, override: true, dadisk: dadisk)
    return
  }
  
  /*
   * Part of the setup step
   * Currently it will never run cause directory will always exist before this program will run
   */
  // checks to see if the directory for the key exist  and if not creates it and check if we need to setup USBKey
  var (directory, _) = checkFileDirectoryExist(fullPath: fullUSBRoot.path)
  if (!directory)
  {
    do
    {
      try fileManager.createDirectory(atPath: fullUSBRoot.path, withIntermediateDirectories: true)
    }
    catch
    {
      // directory keyPath couldn't be created
      logger("Directory for %@ couldn't be created. Error - %@", "Error", keyPath, errno)
      eject(fullUSBRoot: fullUSBRoot, diskPath: diskPath!, dadisk: dadisk)
      return
    }
  }
  
  
  
  // Decrypt the SPARSE image (using the keyfile)
  logger("Decrypting Sparse Image", "Info")
  let path = fullUSBRoot.appendingPathComponent(keyPath)
  let fileHandle = FileHandle(forReadingAtPath: path.path)
  let urlDevice = URL(fileURLWithPath: diskPath!)
  shell(stdInput: fileHandle, args: "hdiutil", "attach", "-stdinpass", urlDevice.path + "/osx.sparseimage")
  
  
  
  // adds rsa keys to ssh from the decrypted image
  (directory, _) = checkFileDirectoryExist(fullPath: mountPoint)
  if (directory)
  {
    do
    {
      let files = try fileManager.contentsOfDirectory(atPath: mountPoint)
      for key in files
      {
        if (key[key.startIndex] != ".")
        {
          shell(args: "ssh-add", "-t", "7200", String(mountPoint + key))
          logger("Add key %@", "Info", key)
        }
      }
    }
    catch
    {
      // if directory that contains rsa doesn't exist error will occur
      logger("Dirctory %@ suddenly disppeared. Error - %@", "Error", mountPoint, errno)
      eject(fullUSBRoot: fullUSBRoot, diskPath: diskPath!, dadisk: dadisk)
      return
    }
  }
  else
  {
    logger("Image didn't decrypt correctly/Image doesn't exist", "Info")
  }
  
  // Eject SPARSE device
  let (terminationStatus, output) = shell(args: "hdiutil", "eject", mountPoint)
  logger("hdiutil eject %@: %@, Status - %@", "Info", mountPoint, output!, terminationStatus)
  
  // Create Insertion hint
  fileManager.createFile(atPath: fullUSBRoot.appendingPathComponent("INSERTED").path , contents: nil, attributes: nil)
  
  // Ejects usbkey
  // TODO add condition to check for EJECT file to eject
  eject(fullUSBRoot: fullUSBRoot, diskPath: diskPath!, dadisk: dadisk)
}

func eject(fullUSBRoot : URL? = nil, diskPath : String, override : Bool = false, dadisk: DADisk?)
{
  let (_, file) = checkFileDirectoryExist(fullPath: fullUSBRoot!.appendingPathComponent("EJECT").path)
  if (file || override)
  {
    let wholeDisk = DADiskCopyWholeDisk(dadisk!)
    DADiskUnmount(dadisk!, DADiskUnmountOptions(kDADiskUnmountOptionForce), nil, nil)
    DADiskEject(wholeDisk!, DADiskEjectOptions(kDADiskEjectOptionDefault), nil, nil)
    logger("diskutl eject %@", "Info", diskPath)
  }
}

func logger(_ description: StaticString, _ type: String, _ args: CVarArg...)
{
  
  if #available(OSX 10.12, *)
  {
    let customLog = OSLog(subsystem: "com.bioneos.usbkey_osx", category: "usbkey")
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
let usbEventDetector = IOUSBDetector(vendorID: IOUSBDetector.SANDISKID, productID: IOUSBDetector.CRUZERFITID)
_ = usbEventDetector?.startDetection()

RunLoop.main.run()
