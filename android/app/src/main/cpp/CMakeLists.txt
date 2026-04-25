cmake_minimum_required(VERSION 3.22.1)

project("mimo_ndi_native")

# Header Search Paths (Project Local)
include_directories(include)

add_library(${CMAKE_PROJECT_NAME} SHARED
        native-lib.cpp)

# Import NDI prebuilt shared library (official CMake way for prebuilt .so)
add_library(ndi SHARED IMPORTED)
set_target_properties(ndi PROPERTIES
        IMPORTED_LOCATION ${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libndi.so)

target_link_libraries(${CMAKE_PROJECT_NAME}
        android
        log
        jnigraphics
        ndi)
