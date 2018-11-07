import Darwin
import IOKit
import IOKit.usb
import Foundation
import DiskArbitration
import os.log

/**
 * Implements a usb detector to receive mounting and removing events to run callback functions in response to these events
 */
class USBDetector
{
  // static final variables to identify a Sandisk Cruzer Fit usb
  static let USB_VENDOR_ID : Int = 0x0781
  static let USB_PRODUCT_ID : Int = 0x5571
  static let USB_VENDOR_KEY : String = "SanDisk"
  static let USB_PRODUCT_KEY : String = "Cruzer Fit"
  
  // a thread use to schedule IONotificationPortRef/DASession objects to monitor events
  private let queue: DispatchQueue
  
  // a port for communication with I/O ports on a computer
  private let notifyPort: IONotificationPortRef
  
  // a notification iterator use to iterate I/O events specialized for I/O remove events
  private var removedIterator: io_iterator_t
  
  // a disk arbitration session for register disk events
  private let session : DASession?
  
  // constructor
  init()
  {
    queue = DispatchQueue.global(qos: DispatchQoS.QoSClass.default)
    
    // creates disk arbitration session
    session = DASessionCreate(CFAllocatorGetDefault().takeRetainedValue())
    
    // setup the session to a dispatch queue
    DASessionSetDispatchQueue(session!, queue)
    
    // creates I/O port to detect of usb device event
    notifyPort = IONotificationPortCreate(kIOMasterPortDefault)!
    
    // setup the notify port to a dispatch queue
    IONotificationPortSetDispatchQueue(notifyPort, queue)
    
    // setting the iterator to zero signalifying no event has occurred
    removedIterator = 0
  }
  
  deinit
  {
    // exiting scquence when program finished
    stopDetection()
  }
  
  /*
   * Starts up detections by add matching notifications for mounting and removing events
   */
  func startDetection() -> Bool
  {
    // checks if there is an event already in the iterator meaning startDetection() has already been called
    guard removedIterator == 0 else
    {
      return true
    }
    
    // a matching dictionary that uses the criteria, vendorID & productID, for a I/O Service Notfication
    let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
    matchingDict[kUSBVendorID] = NSNumber(value: USBDetector.USB_VENDOR_ID)
    matchingDict[kUSBProductID] = NSNumber(value: USBDetector.USB_PRODUCT_ID)
    
    // a matching dictionary that matches usb device with the usb's vendor, product, and volume key for Disk Arbitration Register
    let matchingDADict : CFDictionary = [kDADiskDescriptionDeviceModelKey as String : USBDetector.USB_PRODUCT_KEY,
      kDADiskDescriptionDeviceVendorKey as String : USBDetector.USB_VENDOR_KEY,
      kDADiskDescriptionVolumeMountableKey as String : 1] as CFDictionary
    
    // a self pointer used as reference for callback function (DARegister and IOService callback functions)
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    
    /*
     * callback function - DADiskDescriptionChangedCallback function
     * the callback function used in a response to an event from DADRegister
     */
    let diskMountCallback : DADiskDescriptionChangedCallback = {
      (disk, watch, context) in
      let diskDict  = DADiskCopyDescription(disk)
      
      // volume name like disk2s1
      let diskname = String(cString: DADiskGetBSDName(disk)!)
      logger(type: "Debug", description: "Newly mounted volume name: %@",  diskname)
      
      // gets the mounted disk volume path from an array of changed keys value from watch array
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
     * callback function – IOServiceMatchingCallback
     * the callback function for events occuring on a specific usb on I/O ports
     */
    let ioRemoveCallback : IOServiceMatchingCallback? = {
      (userData, iterator) in
      var nextService = IOIteratorNext(iterator)
      
      // iterates through all new I/O services called by event I/O notification function
      while (nextService != 0)
      {
        usbkeyRemoveCtl()
        nextService = IOIteratorNext(iterator)
      }
    };
    
    // Setup the disk arbiration notification for volume path change
    DARegisterDiskDescriptionChangedCallback(session!,matchingDADict,
      kDADiskDescriptionWatchVolumePath.takeRetainedValue() as CFArray, diskMountCallback, selfPtr)
    
    /*
     * Setting the notifications for physical removal of a specific usb
     * Returning a status value responding to if the new Notification Service was configure correctly
     */
    let IONotificationStatus = IOServiceAddMatchingNotification(
      notifyPort, kIOTerminatedNotification,
      matchingDict, ioRemoveCallback, selfPtr, &removedIterator
    )
    
    // Checks if there was an error in the configuration of notification
    guard IONotificationStatus == 0 else
    {
      if removedIterator != 0
      {
        IOObjectRelease(removedIterator)
        removedIterator = 0
      }
      logger(type: "Error", description: "Detection failed to start!")
      logger(type: "Error", description: "IOService remove matching notification setup failed. Status:  %@", IONotificationStatus)
      return false
    }
    
    // sets io_iterator to a ready io_object_t to be receive for an event
    IOIteratorNext(removedIterator)
    
    // detector display notificationo starts
    logger(type: "Info", description: "IOService starting detection of usb removal events..")
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
    
    logger(type: "Debug", description: "Stopping detection for usb removal events.")
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
    logger(type: "Debug", description: "Ejecting USB: %@", diskPath.path)
  }
}

/**
 * Sents log message to the console
 */
func logger(type: String, description: StaticString, _ args: CVarArg...)
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


// Controller Functions

/**
 * Controls usbkey events when usb is removed from the computer
 * Removes rsa keys from ssh
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
    logger(type: "Error", description: "Directory ~/Library/ can't be found. Cannot finish usb removal actions.")
    return
  }
  
  // checks if INSERT file exist if not error will occur
  let isPath = FileManager.default.fileExists(atPath: fullUSBRoot.appendingPathComponent("INSERTED").path)
  if (!isPath)
  {
    logger(type: "Error", description: "Can't find file: %@.  Cannot finish usb removal actions.",
           fullUSBRoot.appendingPathComponent("INSERTED").path)
  }
  else
  {
    do
    {
      try FileManager.default.removeItem(at: URL(fileURLWithPath: fullUSBRoot.appendingPathComponent("INSERTED").path))
      
      // removes all keys from ssh
      shell(args: "ssh-add", "-D")
      logger(type: "Info", description: "Removed all RSA keys.")
      
      // lockscreen
      shell("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", args: "-suspend")
      logger(type: "Debug", description: "Locking screen.")
    }
    catch
    {
      // fails if file did exist but suddenly disappears
      logger(type: "Error", description: "INSERTED file located at %@ Dissappeared. Error - %@", fullUSBRoot.path, errno)
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
    logger(type: "Error", description: "Directory ~/Library/ can't be found. Error - %@", errno)
    eject(diskPath: diskPath, override: true, dadisk: dadisk)
    return
  }
  
  // checks to see if the directory for the key exist  and if not creates it and check if we need to setup USBKey
  if (!FileManager.default.fileExists(atPath: fullUSBRoot.path))
  {
    logger(type: "Error", description: "USB Key file doesn't exist... Ejecting usb.")
    eject(fullUSBRoot: fullUSBRoot, diskPath: diskPath, dadisk: dadisk)
    return
  }
  
  // decrypt the SPARSE image (using the keyfile output)
  logger(type: "Info", description: "Decrypting sparse image...")
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
          logger(type: "Info", description: "Adding ssh key %@", key)
        }
      }
      shell("/usr/bin/osascript", args: "-e", "display notification \"Keys have been added\" with title \"UsbkeyCtl\"")
      
      // create INSERTED file
      FileManager.default.createFile(atPath: fullUSBRoot.appendingPathComponent("INSERTED").path , contents: nil, attributes: nil)
    }
    catch
    {
      // if directory that contains rsa doesn't exist error will occur
      logger(type: "Error", description: "Dirctory %@ does not exist. Error - %@", mountPoint, errno)
    }
  }
  else
  {
    logger(type: "Error", description: "Image didn't decrypt correctly/Sparse image could not be found!")
  }
  
  // eject SPARSE disk image
  let (terminationStatus, output) = shell(args: "hdiutil", "eject", mountPoint)
  logger(type: "Info", description: "Eject for mount point %@: %@, Status - %@", mountPoint, output!, terminationStatus)
  
  // ejects usbkey disk
  eject(fullUSBRoot: fullUSBRoot, diskPath: diskPath, dadisk: dadisk)
}

/*
 * the driver that will be run or simply the main function
 */
let usbEventDetector = USBDetector()
_ = usbEventDetector.startDetection()

RunLoop.main.run()
