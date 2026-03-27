#ifndef NDI_Bridging_Header_h
#define NDI_Bridging_Header_h

// Define that we are linking statically (Required for iOS .a library)
#define PROCESSINGNDILIB_STATIC 1

// Import the main NDI header
#import "Processing.NDI.Lib.h"

// 🛠️ CRITICAL: Import the Flutter plugin registrant so Swift can see it
#import "GeneratedPluginRegistrant.h"

#endif /* NDI_Bridging_Header_h */
