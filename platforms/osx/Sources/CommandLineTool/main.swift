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
  
  // how usb device is identified
  private let vendorID: Int
  private let productID: Int
  
  // schedules IOService objects or matching notfications on a thread (1)
  private let queueIO: DispatchQueue
  
  // use default ports to create a notification object to communication with IOkit
  private let notifyPort: IONotificationPortRef
  
  // notification iterator which holds new removed notification from IOService
  private var removedIterator: io_iterator_t
  
  // thread (2) to schedule DASession to run Callback functions like DescriptionChangedCallback
  private let queueDA : DispatchQueue?
  
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
    queueDA = DispatchQueue.global(qos: DispatchQoS.QoSClass.background)
    
    // creates session
    session = DASessionCreate(CFAllocatorGetDefault().takeRetainedValue())
    
    // setups the session to capture registered events
    DASessionSetDispatchQueue(session!, queueDA)
    
    // Setting up IOkit port to detect removal of usb device
    queueIO = DispatchQueue.global(qos: DispatchQoS.QoSClass.default) /*(label: "IODetector")*/
    let notifyPort = IONotificationPortCreate(kIOMasterPortDefault)
    guard notifyPort != nil else
    {
      // checking for errors
      return nil
    }
    self.notifyPort = notifyPort!
    
    //setup the dispatch queue to capture io notifications
    IONotificationPortSetDispatchQueue(notifyPort, queueIO)
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
      if #available(OSX 10.12, *)
      {
        os_log("Name of Volume %s", log: OSLog.default, type: .info, diskname)
      }
      else
      {
        // Fallback on earlier versions
        NSLog("Name of Volume %s", diskname)
      }
      
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
      
      if #available(OSX 10.12, *)
      {
        os_log("Detection Fails to Start", log: OSLog.default, type: .info)
        os_log("IOService Remove Matching Notification Setup Failed to Setup Error %zd",
               log: OSLog.default, type: .error, removeAddNotificationStatus)
      }
      else
      {
        // Fallback on earlier versions
        NSLog("Detection Fails to Start")
        NSLog("IOService Remove Matching Notification Setup Failed Error %zd", removeAddNotificationStatus)
      }
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
    
    if #available(OSX 10.12, *)
    {
      os_log("Stop Detection", log: OSLog.default, type: .info)
    }
    else
    {
      // Fallback on earlier versions
      NSLog("Stop Detection")
    }
  }
  
}

// Helper functions

/*
 * Runs shell commands
 */
@discardableResult
func shell(_ args: String... , launchPath : String = "/usr/bin/env") -> (Int32, String?)
{
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
 * Decrypts and attach image to disk
 */
func decryptImage(keyPath: URL, sparsePath: String) -> Void
{
  let fileHandle = FileHandle(forReadingAtPath: keyPath.path)
  let urlDevice = URL(fileURLWithPath: sparsePath)
  
  let process = Process()
  process.launchPath = "/usr/bin/env"
  process.arguments =  ["hdiutil", "attach", "-stdinpass", urlDevice.path + "/osx.sparseimage"] // arguments to run decryptions
  process.standardInput = fileHandle // standard input holding the key to be pass for decryptions
  
  let out = Pipe()
  process.standardOutput = out
  process.launch()
  
  let data = out.fileHandleForReading.readDataToEndOfFile()
  let output = NSString(data: data, encoding: String.Encoding.utf8.rawValue)
  process.waitUntilExit()
  
  if #available(OSX 10.12, *)
  {
    os_log("Output of Pipeline (printf $(cat keyPath) | hdiutil attach -stdnipass osx.sparseimage). Output - %s",
           log: OSLog.default, type: .info, output ?? "No Output")
  }
  else
  {
    // Fallback on earlier versions
    NSLog("Output of Pipeline (printf $(cat keyPath) | hdiutil attach -stdnipass osx.sparseimage). Output - %s",  output ?? "No Output")
  }
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



//Control Usbkey Functions

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
    if #available(OSX 10.12, *)
    {
      os_log("Directory ~/Library/ can't be find. Error - %{errno}d", log: OSLog.default, type: .info, errno)
    }
    else
    {
      // Fallback on earlier versions
      NSLog("Error - Directory ~/Library/ can't be find. Error - %{errno}d", errno)
    }
    return
  }
  
  
  
  // checks if INSERT file exist if not error will occur
  let (_, file) = checkFileDirectoryExist(fullPath: fullUSBRoot.appendingPathComponent("INSERTED").path )
  if (!file)
  {
    if #available(OSX 10.12, *)
    {
      //let nsError = error as NSError
      os_log("Can't find file path %s" , log: OSLog.default, type: .info, fullUSBRoot.appendingPathComponent("INSERTED").path)
    }
    else
    {
      // Fallback on earlier versions
      NSLog("Can't find file path %s", fullUSBRoot.appendingPathComponent("INSERTED").path)
    }
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
      if #available(OSX 10.12, *)
      {
        //let nsError = error as NSError
        os_log("INSERTED file located at %s Dissappeared. Error - %{errno}d", log: OSLog.default, type: .error, fullUSBRoot.path, errno)
      }
      else
      {
        // Fallback on earlier versions
        NSLog("Error - INSERTED file located at %s Dissappeared. Error - %{errno}d", fullUSBRoot.path, errno)
      }
      return
    }
  }
  
  // goes to sleep mode
  // shell("pmset", "displaysleepnow")
  
  // lockscreen/logs off
  shell("-suspend", launchPath: "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession")
  if #available(OSX 10.12, *)
  {
    os_log("Lockscreen", log: OSLog.default, type: .info)
  }
  else
  {
    // Fallback on earlier versions
    NSLog("Lockscreen")
  }
  
  // removes all keys from ssh
  shell("ssh-add", "-D")
  if #available(OSX 10.12, *)
  {
    os_log("ssh-add -D: Removed all RSA keys", log: OSLog.default, type: .info)
  }
  else
  {
    // Fallback on earlier versions
    NSLog("ssh-add -D: Removed all RSA keys")
  }
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
    if #available(OSX 10.12, *)
    {
      os_log("Directory ~/Library/ can't be find. Error - %{errno}d", log: OSLog.default, type: .error, errno)
    }
    else
    {
      // Fallback on earlier versions
      NSLog("Error - Directory ~/Library/ can't be find %{errno}d", errno)
    }
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
      // TODO add logs and display saying that directory keyPath couldn't be created
      if #available(OSX 10.12, *)
      {
        //let nsError = error as NSError
        os_log("Directory for %s couldn't be created. Error - %{errno}d", log: OSLog.default, type: .error, keyPath, errno)
      }
      else
      {
        // Fallback on earlier versions
        NSLog("Directory for %s couldn't be created. Error - %{errno}d", keyPath, errno)
      }
      
      eject(fullUSBRoot: fullUSBRoot, diskPath: diskPath!, dadisk: dadisk)
      return
    }
  }
  
  
  
  // Decrypt the SPARSE image (using the keyfile)
  if #available(OSX 10.12, *)
  {
    os_log("Decrypting Sparse Image", log: OSLog.default, type: .info)
  }
  else
  {
    // Fallback on earlier versions
    NSLog("Decrypting Sparse Image")
  }
  let path = fullUSBRoot.appendingPathComponent(keyPath)
  decryptImage(keyPath: path , sparsePath: diskPath!)
  
  
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
          shell("ssh-add", "-t", "7200", String(mountPoint + key)) //adds rsa key to ssh
          if #available(OSX 10.12, *)
          {
            os_log("Add key %s", log: OSLog.default, type: .info, key)
          }
          else
          {
            // Fallback on earlier versions
            NSLog("Add key %s", key)
          }
        }
      }
      
    }
    catch
    {
      // if directory that contains rsa doesn't exist error will occur
      if #available(OSX 10.12, *)
      {
        os_log("Dirctory %s suddenly disppeared. Error - %{errno}d", log: OSLog.default, type: .error, mountPoint, errno)
      }
      else
      {
        // Fallback on earlier versions
        NSLog("Error - Dirctory %s suddenly disppeared. Error - %{error}d", mountPoint, errno)
      }
      eject(fullUSBRoot: fullUSBRoot, diskPath: diskPath!, dadisk: dadisk)
      return
    }
  }
  else
  {
    if #available(OSX 10.12, *)
    {
      //let nsError = error as NSError
      os_log("Image didn't decrypt correctly/Image doesn't exist", log: OSLog.default, type: .info)
    }
    else
    {
      // Fallback on earlier versions
      NSLog("Image didn't decrypt correctly/Image doesn't exist")
    }
    
    
  }
  
  // Eject SPARSE device
  let (terminationStatus, output) = shell("hdiutil", "eject", mountPoint)
  if #available(OSX 10.12, *)
  {
    os_log("hdiutil eject %s: %s, Status - %d", log: OSLog.default,
           type: .info, mountPoint, output!, terminationStatus)
  }
  else
  {
    // Fallback on earlier versions
    NSLog("diskutl eject %s: %s, Status - %d", mountPoint, output!, terminationStatus)
  }
  
  // Create Insertion hint
  fileManager.createFile(atPath: fullUSBRoot.appendingPathComponent("INSERTED").path , contents: nil, attributes: nil)
  
  // Ejects usbkey
  // TODO add condition to check for EJECT file to eject
  eject(fullUSBRoot: fullUSBRoot, diskPath: diskPath!, dadisk: dadisk)
}

func ejectHelper (diskPath : String, dadisk: DADisk?)
{
  let wholeDisk = DADiskCopyWholeDisk(dadisk!)
  DADiskUnmount(dadisk!, DADiskUnmountOptions(kDADiskUnmountOptionForce), nil, nil)
  DADiskEject(wholeDisk!, DADiskEjectOptions(kDADiskEjectOptionDefault), nil, nil)
  
  if #available(OSX 10.12, *)
  {
    os_log("diskutl eject %s", log: OSLog.default, type: .info, diskPath)
  }
  else
  {
    // Fallback on earlier versions
    NSLog("diskutl eject %s", diskPath)
  }
}

func eject(fullUSBRoot : URL? = nil, diskPath : String, override : Bool = false, dadisk: DADisk?){
  if (override)
  {
    if #available(OSX 10.12, *)
    {
      os_log("Without EJECT file" , log: OSLog.default, type: .info)
    }
    else
    {
      // Fallback on earlier versions
      NSLog("Without Eject file")
    }
    ejectHelper(diskPath: diskPath, dadisk: dadisk)
  }
  else
  {
    let (_, file) = checkFileDirectoryExist(fullPath: fullUSBRoot!.appendingPathComponent("EJECT").path)
    if (file)
    {
      ejectHelper(diskPath: diskPath, dadisk: dadisk)
    }
  }
}



/*
 * the driver that will be run or simply the main function
 */
let usbEventDetector = IOUSBDetector(vendorID: 0x0781, productID: 0x5571)
_ = usbEventDetector?.startDetection()

RunLoop.main.run()

