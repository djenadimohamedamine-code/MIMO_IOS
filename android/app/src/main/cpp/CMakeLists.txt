cmake_minimum_required(VERSION 3.22.1)

project("mimo_ndi_native")

# Header Search Paths
include_directories("../../../../../ios/NDISDK/include") # Reuse headers if possible or add separate one

add_library(${CMAKE_PROJECT_NAME} SHARED
        native-lib.cpp)

# Use NDI library from jniLibs
find_library(ndi_lib
        ndi
        ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})

target_link_libraries(${CMAKE_PROJECT_NAME}
        android
        log
        ${ndi_lib})
