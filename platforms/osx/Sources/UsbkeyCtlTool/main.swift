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
  // Static final variables to identify a Sandisk Cruzer Fit usb
  static let USB_VENDOR_ID: Int = 0x0781
  static let USB_PRODUCT_ID: Int = 0x5571
  static let USB_VENDOR_KEY: String = "SanDisk"
  static let USB_PRODUCT_KEY: String = "Cruzer Fit"

  // A port for communication with I/O ports on a computer
  private let notifyPort: IONotificationPortRef

  // A notification iterator use to iterate I/O events specialized for I/O remove events
  private var removedIterator: io_iterator_t

  // A disk arbitration session for register disk events
  private let session: DASession?

  // Constructor
  init()
  {
    // Creates disk arbitration session
    session = DASessionCreate(CFAllocatorGetDefault().takeRetainedValue())

    // Creates I/O port to detect of usb device event
    notifyPort = IONotificationPortCreate(kIOMasterPortDefault)!

    // Setting the iterator to zero signalifying no event has occurred
    removedIterator = 0

    // Creates a run loop to schedule and monitor events automatically for IONotificationPortRef/DASession objects
    DASessionScheduleWithRunLoop(session!, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort)?.takeRetainedValue(), CFRunLoopMode.commonModes)
  }

  deinit
  {
    // Exiting scquence when program finished
    stopDetection()
    logger(type: "Debug", description: "Stopping detection for usb removal events.")
  }

  /*
   * Starts up detections by add matching notifications for mounting and removing events
   */
  func startDetection() -> Bool
  {
    // A matching dictionary that uses the criteria, vendorID & productID, for a I/O Service Notfication
    let matchingIODict: NSMutableDictionary = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
    matchingIODict[kUSBVendorID] = NSNumber(value: USBDetector.USB_VENDOR_ID)
    matchingIODict[kUSBProductID] = NSNumber(value: USBDetector.USB_PRODUCT_ID)

    // A matching dictionary that matches usb device with the usb's vendor, product, and volume key for Disk Arbitration Register
    let matchingDADict: CFDictionary = [kDADiskDescriptionDeviceModelKey as String: USBDetector.USB_PRODUCT_KEY,
      kDADiskDescriptionDeviceVendorKey as String: USBDetector.USB_VENDOR_KEY,
      kDADiskDescriptionVolumeMountableKey as String: 1] as CFDictionary

    // A self pointer used as reference for callback function (DARegister and IOService callback functions)
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()

    /*
     * Callback function - DADiskDescriptionChangedCallback function
     * The callback function used in a response to an event from DADRegister
     */
    let diskMountCallback: DADiskDescriptionChangedCallback = {
      (disk, watch, context) in
      let diskDict  = DADiskCopyDescription(disk)

      // Gets the mounted disk volume path from an array of changed keys value from watch array
      let volumeArray = watch as Array
      let volumeIndex: CFString = volumeArray[0] as! CFString
      if let dictionary = diskDict as? [NSString: Any]
      {
        if let volumePath = dictionary[volumeIndex] as! URL?
        {
          usbkeyInsertCtl(keyPath: "key", diskPath: volumePath, insertedDisk: disk)
        }
      }
    }

    /*
     * Callback function – IOServiceMatchingCallback
     * The callback function for events occuring on a specific usb on I/O ports
     */
    let ioRemoveCallback: IOServiceMatchingCallback? = {
      (userData, iterator) in
      // Iterates through all new I/O services called by event I/O notification function
      while (IOIteratorNext(iterator) != 0)
      {
        usbkeyRemoveCtl()
      }
    };

    // Setup the disk arbiration notification for volume path change
    DARegisterDiskDescriptionChangedCallback(session!,matchingDADict,
      kDADiskDescriptionWatchVolumePath.takeRetainedValue() as CFArray, diskMountCallback, selfPtr)

    /*
     * Setting the notifications for physical removal of a specific usb
     * Returning a status value responding to if the new Notification Service was configure correctly
     * RemovedIterator is not empty/armed to receive notifcations when this function is first called
     */
    let IONotificationStatus = IOServiceAddMatchingNotification(
      notifyPort, kIOTerminatedNotification,
      matchingIODict, ioRemoveCallback, selfPtr, &removedIterator
    )

    // Checks if there was an error in the configuration of notification
    guard IONotificationStatus == 0 else
    {
      stopDetection()
      logger(type: "Error", description: "Detection failed to start!")
      logger(type: "Error", description: "IOService remove matching notification setup failed. Status:  %@", IONotificationStatus)
      return false
    }

    // Sets/arms io_iterator to a ready io_object_t to be receive for an event
    IOIteratorNext(removedIterator)

    // Detector display notificationo starts
    logger(type: "Info", description: "IOService starting detection of usb removal events..")
    shell("/usr/bin/osascript", args: "-e", "display notification \"Start Detection\" with title \"UsbkeyCtl\"")
    return true
  }

  // Release IO/DA objects
  func stopDetection()
  {
    guard self.removedIterator != 0 else
    {
      return
    }
    IOObjectRelease(self.removedIterator)
    IONotificationPortDestroy(notifyPort)
    DASessionUnscheduleFromRunLoop(session!, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    self.removedIterator = 0
  }
}

// Helper functions

/*
 * Runs shell commands
 */
@discardableResult
func shell(_ launchPath: String = "/usr/bin/env", stdInput: FileHandle? = nil, args: String...) -> (Int32, String?)
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
 * Logs messages in the Console application on osx
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

/**
 * Ejects and Unmounts disk object from computer
 */
func eject(fullUSBRoot: URL? = nil, diskPath: URL, dadisk: DADisk?, forceEject: Bool = false)
{
  let isPath = FileManager.default.fileExists(atPath: fullUSBRoot!.appendingPathComponent("EJECT").path)
  if (isPath || forceEject)
  {
    let wholeDisk = DADiskCopyWholeDisk(dadisk!)
    DADiskUnmount(dadisk!, DADiskUnmountOptions(kDADiskUnmountOptionForce), nil, nil)
    DADiskEject(wholeDisk!, DADiskEjectOptions(kDADiskEjectOptionDefault), nil, nil)
    logger(type: "Debug", description: "Ejecting USB: %@", diskPath.path)
  }
}


// Control Functions

/**
 * Controls usbkey events when usb is removed from the computer
 * Removes rsa keys from ssh
 * Deletes INSERT file in usbkey_root directory
 * Calls Locksreen protocol
 */
func usbkeyRemoveCtl (usbkey_root: String = "usbkey")
{
  let fullUSBRoot: URL
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

  // Checks if INSERT file exist if not error will occur
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

      // Removes all keys from ssh
      shell(args: "ssh-add", "-D")
      logger(type: "Info", description: "Removed all RSA keys.")

      // Lockscreen
      shell("/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", args: "-suspend")
      logger(type: "Debug", description: "Locking screen.")
    }
    catch
    {
      // Fails if file did exist but suddenly disappears
      logger(type: "Error", description: "INSERTED file located at %@ Dissappeared. Error - %@", fullUSBRoot.path, errno)
    }
  }
}
/**
 * Controls usbkey events when usb is inserted into the computer
 * Decrypts Image and add rsa keys to ssh
 * Ejects both the image and usb after process is done
 */
func usbkeyInsertCtl(keyPath: String, diskPath: URL, usbkey_root: String = "usbkey/", insertedDisk: DADisk?)
{
  // Where the encrypted image will mounted to when decrypted – naming of image was created prior
  let mountPoint: String = "/Volumes/usbkey/"
  var fullUSBRoot: URL
  var fullKeyPath: URL
  do
  {
    fullUSBRoot = try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask,
      appropriateFor: nil, create: false).appendingPathComponent(usbkey_root)
    fullKeyPath = fullUSBRoot.appendingPathComponent(keyPath)
  }
  catch
  {
    logger(type: "Error", description: "Directory ~/Library/ can't be found. Error - %@", errno)
    eject(diskPath: diskPath, dadisk: insertedDisk, forceEject: true)
    return
  }

  // Checks to see if the directory for the key exist  and if not creates it and check if we need to setup USBKey
  if (!FileManager.default.fileExists(atPath: fullUSBRoot.path) || !FileManager.default.fileExists(atPath: fullKeyPath.path))
  {
    logger(type: "Error", description: "USB Key file doesn't exist... Ejecting usb.")
    eject(fullUSBRoot: fullUSBRoot, diskPath: diskPath, dadisk: insertedDisk)
    return
  }

  // Decrypt the SPARSE image (using the keyfile output)
  logger(type: "Info", description: "Decrypting sparse image...")
  let fileHandle = FileHandle(forReadingAtPath: fullKeyPath.path)
  shell(stdInput: fileHandle, args: "hdiutil", "attach", diskPath.path + "/osx.sparseimage", "-stdinpass")

  // Adds rsa keys to ssh from the decrypted image
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

      // Create INSERTED file
      FileManager.default.createFile(atPath: fullUSBRoot.appendingPathComponent("INSERTED").path , contents: nil, attributes: nil)
    }
    catch
    {
      // If directory that contains rsa doesn't exist error will occur
      logger(type: "Error", description: "Dirctory %@ does not exist. Error - %@", mountPoint, errno)
    }

    // Eject the encrypted disk disk image with the rsa key files
    let encryptedDisk = DADiskCreateFromVolumePath(
      kCFAllocatorDefault,
      DASessionCreate(CFAllocatorGetDefault().takeRetainedValue())!,
      CFURLCreateWithString(kCFAllocatorDefault, mountPoint as CFString, nil)
    )
    eject(fullUSBRoot: fullUSBRoot, diskPath: URL(string: mountPoint)!, dadisk: encryptedDisk, forceEject: true)
  }
  else
  {
    logger(type: "Error", description: "Image didn't decrypt correctly/Sparse image could not be found!")
  }

  // Ejects usbkey disk
  eject(fullUSBRoot: fullUSBRoot, diskPath: diskPath, dadisk: insertedDisk)
}

/*
 * The driver that will be run or simply the main function
 */
let usbEventDetector = USBDetector()
_ = usbEventDetector.startDetection()

CFRunLoopRun()
