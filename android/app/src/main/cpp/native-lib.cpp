#include <jni.h>
#include <string>
#include <vector>
#include <algorithm> // For std::min and std::max
#include <cstring>   // For memcpy
#include <android/bitmap.h>
#include <android/log.h>
#include "Processing.NDI.Lib.h"

#define TAG "NDINative"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

extern "C" JNIEXPORT jobject JNICALL
Java_com_antigravity_ndi_1player_1app_MainActivity_getNativeSources(JNIEnv* env, jobject /* this */) {
    if (!NDIlib_initialize()) {
        LOGE("NDIlib_initialize failed");
        return nullptr;
    }
    NDIlib_find_create_t find_create_settings;
    NDIlib_find_instance_t p_find = NDIlib_find_create_v2(&find_create_settings);
    if (!p_find) return nullptr;
    NDIlib_find_wait_for_sources(p_find, 1000);
    uint32_t no_sources = 0;
    const NDIlib_source_t* p_sources = NDIlib_find_get_current_sources(p_find, &no_sources);
    jclass listClass = env->FindClass("java/util/ArrayList");
    jmethodID listInit = env->GetMethodID(listClass, "<init>", "()V");
    jmethodID listAdd = env->GetMethodID(listClass, "add", "(Ljava/lang/Object;)Z");
    jobject listObj = env->NewObject(listClass, listInit);
    for (uint32_t i = 0; i < no_sources; i++) {
        jstring sourceName = env->NewStringUTF(p_sources[i].p_ndi_name);
        env->CallBooleanMethod(listObj, listAdd, sourceName);
    }
    NDIlib_find_destroy(p_find);
    return listObj;
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_antigravity_ndi_1player_1app_NdiView_createReceiver(JNIEnv* env, jobject /* this */, jstring sourceName, jboolean isLowBandwidth) {
    if (!NDIlib_initialize()) {
        LOGE("NDIlib_initialize failed in createReceiver");
        return 0;
    }
    const char* native_name = env->GetStringUTFChars(sourceName, nullptr);
    NDIlib_recv_create_v3_t recv_create;
    recv_create.source_to_connect_to.p_ndi_name = native_name;
    // Switch back to "Fastest" which is UYVY 4:2:2. It's more CPU efficient for conversion.
    recv_create.color_format = NDIlib_recv_color_format_fastest; 
    recv_create.bandwidth = isLowBandwidth ? NDIlib_recv_bandwidth_lowest : NDIlib_recv_bandwidth_highest;
    recv_create.allow_video_fields = false;
    
    NDIlib_recv_instance_t p_instance = NDIlib_recv_create_v3(&recv_create);
    env->ReleaseStringUTFChars(sourceName, native_name);
    return (jlong)p_instance;
}

extern "C" JNIEXPORT void JNICALL
Java_com_antigravity_ndi_1player_1app_NdiView_destroyReceiver(JNIEnv* env, jobject /* this */, jlong p_instance) {
    if (p_instance) NDIlib_recv_destroy((NDIlib_recv_instance_t)p_instance);
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_antigravity_ndi_1player_1app_NdiView_getFrameResolution(JNIEnv* env, jobject /* this */, jlong p_instance) {
    int res[2] = {0, 0};
    if (p_instance) {
        NDIlib_recv_instance_t recv = (NDIlib_recv_instance_t)p_instance;
        NDIlib_video_frame_v2_t video_frame;
        if (NDIlib_recv_capture_v2(recv, &video_frame, nullptr, nullptr, 100) == NDIlib_frame_type_video) {
            res[0] = video_frame.xres;
            res[1] = video_frame.yres;
            NDIlib_recv_free_video_v2(recv, &video_frame);
        }
    }
    jintArray result = env->NewIntArray(2);
    env->SetIntArrayRegion(result, 0, 2, res);
    return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_antigravity_ndi_1player_1app_NdiView_captureFrameToBitmap(JNIEnv* env, jobject /* this */, jlong p_instance, jobject bitmap) {
    if (!p_instance) return 0;
    NDIlib_recv_instance_t recv = (NDIlib_recv_instance_t)p_instance;
    NDIlib_video_frame_v2_t video_frame;
    
    NDIlib_frame_type_e type = NDIlib_recv_capture_v2(recv, &video_frame, nullptr, nullptr, 10);
    
    if (type == NDIlib_frame_type_video) {
        AndroidBitmapInfo info;
        void* pixels;
        
        if (AndroidBitmap_getInfo(env, bitmap, &info) < 0) {
            NDIlib_recv_free_video_v2(recv, &video_frame);
            return 0;
        }

        if (video_frame.xres != (int)info.width || video_frame.yres != (int)info.height) {
            NDIlib_recv_free_video_v2(recv, &video_frame);
            return -1; 
        }

        if (AndroidBitmap_lockPixels(env, bitmap, &pixels) < 0) {
            NDIlib_recv_free_video_v2(recv, &video_frame);
            return 0;
        }
        
        const int width  = video_frame.xres;
        const int height = video_frame.yres;
        const int src_stride = video_frame.line_stride_in_bytes;
        const uint8_t* src_ptr = video_frame.p_data;
        const int dst_stride = info.stride;
        uint32_t* dst_ptr = (uint32_t*)pixels;
        
        bool success = false;
        
        // IMPROVED YUV -> RGB conversion (BT.601)
        if (video_frame.FourCC == NDIlib_FourCC_video_type_UYVY) {
            for (int y = 0; y < height; y++) {
                const uint8_t* src_row = src_ptr + y * src_stride;
                uint32_t* dst_row = (uint32_t*)((uint8_t*)dst_ptr + y * dst_stride);
                
                for (int x = 0; x < width - 1; x += 2) {
                    // UYVY order: Byte 0:U, Byte 1:Y0, Byte 2:V, Byte 3:Y1
                    int u = (int)src_row[2*x] - 128;
                    int y0 = (int)src_row[2*x+1] - 16;
                    int v = (int)src_row[2*x+2] - 128;
                    int y1 = (int)src_row[2*x+3] - 16;
                    
                    // Standard BT.601 Coefficients
                    auto clamp = [](int v) -> uint8_t { return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v)); };
                    
                    int r0 = (298 * y0 + 409 * v + 128) >> 8;
                    int g0 = (298 * y0 - 100 * u - 208 * v + 128) >> 8;
                    int b0 = (298 * y0 + 516 * u + 128) >> 8;
                    
                    int r1 = (298 * y1 + 409 * v + 128) >> 8;
                    int g1 = (298 * y1 - 100 * u - 208 * v + 128) >> 8;
                    int b1 = (298 * y1 + 516 * u + 128) >> 8;
                    
                    dst_row[x]     = (0xFF << 24) | (clamp(r0) << 16) | (clamp(g0) << 8) | clamp(b0);
                    dst_row[x + 1] = (0xFF << 24) | (clamp(r1) << 16) | (clamp(g1) << 8) | clamp(b1);
                }
            }
            success = true;
        } 
        else if (video_frame.FourCC == NDIlib_FourCC_video_type_BGRA || 
                 video_frame.FourCC == NDIlib_FourCC_video_type_BGRX ||
                 video_frame.FourCC == NDIlib_FourCC_video_type_RGBA ||
                 video_frame.FourCC == NDIlib_FourCC_video_type_RGBX) {
            for (int y = 0; y < height; y++) {
                memcpy((uint8_t*)dst_ptr + y * dst_stride, src_ptr + y * src_stride, width * 4);
            }
            success = true;
        }
        
        AndroidBitmap_unlockPixels(env, bitmap);
        NDIlib_recv_free_video_v2(recv, &video_frame);
        return success ? 1 : 0;
    }
    
    if (type != NDIlib_frame_type_none) {
        NDIlib_recv_free_video_v2(recv, &video_frame);
    }
    return 0;
}
