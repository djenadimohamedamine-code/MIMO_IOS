cmake_minimum_required(VERSION 3.22.1)

project("mimo_ndi_native")

# Header Search Paths (Project Local)
include_directories(include)

add_library(${CMAKE_PROJECT_NAME} SHARED
        native-lib.cpp)

# Use NDI library from jniLibs (Specific to the ABI during build)
find_library(ndi_lib
        ndi
        PATHS ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}
        NO_DEFAULT_PATH)

target_link_libraries(${CMAKE_PROJECT_NAME}
        android
        log
        jnigraphics # Essential for Bitmap handling (Preview/NDI)
        ${ndi_lib})
