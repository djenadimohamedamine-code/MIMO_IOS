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

// Fixed case sensitivity: NdiView (Kotlin) needs NdiView (JNI)
extern "C" JNIEXPORT jlong JNICALL
Java_com_antigravity_ndi_1player_1app_NdiView_createReceiver(JNIEnv* env, jobject /* this */, jstring sourceName, jboolean isLowBandwidth) {
    if (!NDIlib_initialize()) {
        LOGE("NDIlib_initialize failed in createReceiver");
        return 0;
    }
    const char* native_name = env->GetStringUTFChars(sourceName, nullptr);
    NDIlib_recv_create_v3_t recv_create;
    recv_create.source_to_connect_to.p_ndi_name = native_name;
    recv_create.color_format = NDIlib_recv_color_format_BGRX_BGRA;
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

extern "C" JNIEXPORT jint JNICALL
Java_com_antigravity_ndi_1player_1app_NdiView_captureFrameToBitmap(JNIEnv* env, jobject /* this */, jlong p_instance, jobject bitmap) {
    if (!p_instance) return 0;
    NDIlib_recv_instance_t recv = (NDIlib_recv_instance_t)p_instance;
    NDIlib_video_frame_v2_t video_frame;
    NDIlib_frame_type_e type = NDIlib_recv_capture_v2(recv, &video_frame, nullptr, nullptr, 16);
    
    if (type == NDIlib_frame_type_video) {
        AndroidBitmapInfo info;
        void* pixels;
        if (AndroidBitmap_getInfo(env, bitmap, &info) < 0) {
            NDIlib_recv_free_video_v2(recv, &video_frame);
            return 0;
        }

        // Safety Buffer Check: ensure received resolution fits in bitmap
        if (video_frame.xres != info.width || video_frame.yres != info.height) {
            // Resolution mismatch, don't copy as it will buffer overflow/crash
            NDIlib_recv_free_video_v2(recv, &video_frame);
            return 0;
        }

        if (AndroidBitmap_lockPixels(env, bitmap, &pixels) < 0) {
            NDIlib_recv_free_video_v2(recv, &video_frame);
            return 0;
        }
        
        const int width  = video_frame.xres;
        const int height = video_frame.yres;
        const int stride = video_frame.line_stride_in_bytes;
        const uint8_t* src = video_frame.p_data;
        uint32_t* dst = (uint32_t*)pixels;
        
        // Check if NDI sends UYVY
        if (video_frame.FourCC == NDIlib_FourCC_video_type_UYVY) {
            for (int y = 0; y < height; y++) {
                const uint8_t* row = src + y * stride;
                for (int x = 0; x < width - 1; x += 2) {
                    uint8_t u  = row[2*x];
                    uint8_t y0 = row[2*x+1];
                    uint8_t v  = row[2*x+2];
                    uint8_t y1 = row[2*x+3];
                    
                    auto yuv2rgb = [](uint8_t Y, uint8_t U, uint8_t V, uint8_t& r, uint8_t& g, uint8_t& b) {
                        int c = Y - 16, d = U - 128, e = V - 128;
                        r = (uint8_t)std::max(0, std::min(255, (298*c + 409*e + 128) >> 8));
                        g = (uint8_t)std::max(0, std::min(255, (298*c - 100*d - 208*e + 128) >> 8));
                        b = (uint8_t)std::max(0, std::min(255, (298*c + 516*d + 128) >> 8));
                    };
                    
                    uint8_t r0, g0, b0, r1, g1, b1;
                    yuv2rgb(y0, u, v, r0, g0, b0);
                    yuv2rgb(y1, u, v, r1, g1, b1);
                    dst[y * width + x]     = (0xFF << 24) | (r0 << 16) | (g0 << 8) | b0;
                    dst[y * width + x + 1] = (0xFF << 24) | (r1 << 16) | (g1 << 8) | b1;
                }
            }
        } else {
            // Assume compatible BGRA/BGRX or similar
            memcpy(pixels, src, (size_t)height * (size_t)info.stride);
        }
        
        AndroidBitmap_unlockPixels(env, bitmap);
        NDIlib_recv_free_video_v2(recv, &video_frame);
        return 1;
    }
    return 0;
}

