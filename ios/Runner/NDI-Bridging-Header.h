#ifndef NDI_Bridging_Header_h
#define NDI_Bridging_Header_h

// Define that we are linking statically (Required for iOS .a library)
#define PROCESSINGNDILIB_STATIC 1

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
// Import the main NDI header (it includes all others: Find, Recv, Send, etc.)
#import "Processing.NDI.Lib.h"
#pragma clang diagnostic pop

#endif /* NDI_Bridging_Header_h */
