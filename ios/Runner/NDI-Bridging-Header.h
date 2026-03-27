#ifndef NDI_Bridging_Header_h
#define NDI_Bridging_Header_h

// Define that we are linking statically (Required for iOS .a library)
#define PROCESSINGNDILIB_STATIC 1

// Import the main NDI header (it includes all others: Find, Recv, Send, etc.)
#import "Processing.NDI.Lib.h"

#endif /* NDI_Bridging_Header_h */
