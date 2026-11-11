#include <jni.h>
#include <string>
#include <vector>
#include <algorithm> // For std::min and std::max
#include <cstring>   // For memcpy, memset
#include <mutex>
#include <android/bitmap.h>
#include <android/log.h>
#include "Processing.NDI.Lib.h"

#define TAG "NDINative"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static NDIlib_find_instance_t g_pFind = nullptr;
static std::mutex g_findMutex;

static bool ensureFinderInitialized() {
    if (!NDIlib_initialize()) {
        LOGE("NDIlib_initialize failed");
        return false;
    }
    std::lock_guard<std::mutex> lock(g_findMutex);
    if (!g_pFind) {
        NDIlib_find_create_t find_create_settings;
        memset(&find_create_settings, 0, sizeof(find_create_settings));
        find_create_settings.show_local_sources = true;
        g_pFind = NDIlib_find_create_v2(&find_create_settings);
        if (!g_pFind) {
            LOGE("NDIlib_find_create_v2 failed");
            return false;
        }
        LOGD("NDIlib finder initialized successfully");
    }
    return true;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_antigravity_ndi_1player_1app_NDIManager_nativeInitFinder(JNIEnv* /* env */, jobject /* this */) {
    return ensureFinderInitialized() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_antigravity_ndi_1player_1app_NDIManager_nativeGetSources(JNIEnv* env, jobject /* this */) {
    if (!ensureFinderInitialized()) return nullptr;

    std::lock_guard<std::mutex> lock(g_findMutex);
    if (!g_pFind) return nullptr;

    // Wait briefly (up to 200ms) for discovery updates without lagging
    NDIlib_find_wait_for_sources(g_pFind, 200);

    uint32_t no_sources = 0;
    const NDIlib_source_t* p_sources = NDIlib_find_get_current_sources(g_pFind, &no_sources);

    jclass listClass = env->FindClass("java/util/ArrayList");
    jmethodID listInit = env->GetMethodID(listClass, "<init>", "()V");
    jmethodID listAdd = env->GetMethodID(listClass, "add", "(Ljava/lang/Object;)Z");
    jobject listObj = env->NewObject(listClass, listInit);

    if (p_sources && no_sources > 0) {
        for (uint32_t i = 0; i < no_sources; i++) {
            if (p_sources[i].p_ndi_name) {
                jstring sourceName = env->NewStringUTF(p_sources[i].p_ndi_name);
                env->CallBooleanMethod(listObj, listAdd, sourceName);
                env->DeleteLocalRef(sourceName);
            }
        }
    }
    return listObj;
}

extern "C" JNIEXPORT jobject JNICALL
Java_com_antigravity_ndi_1player_1app_MainActivity_getNativeSources(JNIEnv* env, jobject thiz) {
    return Java_com_antigravity_ndi_1player_1app_NDIManager_nativeGetSources(env, thiz);
}

extern "C" JNIEXPORT void JNICALL
Java_com_antigravity_ndi_1player_1app_NDIManager_nativeDestroyFinder(JNIEnv* /* env */, jobject /* this */) {
    std::lock_guard<std::mutex> lock(g_findMutex);
    if (g_pFind) {
        NDIlib_find_destroy(g_pFind);
        g_pFind = nullptr;
        LOGD("NDIlib finder destroyed");
    }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_antigravity_ndi_1player_1app_NdiView_createReceiver(JNIEnv* env, jobject /* this */, jstring sourceName, jboolean isLowBandwidth) {
    if (!NDIlib_initialize()) return 0;
    const char* native_name = env->GetStringUTFChars(sourceName, nullptr);
    if (!native_name) return 0;

    NDIlib_recv_create_v3_t recv_create;
    memset(&recv_create, 0, sizeof(recv_create)); // Critical: zero memory to prevent garbage stack pointers!

    std::string matched_url;
    {
        std::lock_guard<std::mutex> lock(g_findMutex);
        if (g_pFind) {
            uint32_t count = 0;
            const NDIlib_source_t* sources = NDIlib_find_get_current_sources(g_pFind, &count);
            for (uint32_t i = 0; i < count; i++) {
                if (sources[i].p_ndi_name && strcmp(sources[i].p_ndi_name, native_name) == 0) {
                    if (sources[i].p_url_address) {
                        matched_url = sources[i].p_url_address;
                    }
                    break;
                }
            }
        }
    }

    recv_create.source_to_connect_to.p_ndi_name = native_name;
    if (!matched_url.empty()) {
        recv_create.source_to_connect_to.p_url_address = matched_url.c_str();
    } else {
        recv_create.source_to_connect_to.p_url_address = nullptr;
    }

    recv_create.color_format = NDIlib_recv_color_format_RGBX_RGBA; 
    // Always use highest bandwidth to guarantee frame reception across all NDI senders (e.g. OBS/vMix without proxy)
    recv_create.bandwidth = NDIlib_recv_bandwidth_highest;
    recv_create.allow_video_fields = false;

    NDIlib_recv_instance_t p_instance = NDIlib_recv_create_v3(&recv_create);
    LOGD("createReceiver: name=%s, url=%s, lowBandwidth=%d -> %p",
         native_name, matched_url.c_str(), (int)isLowBandwidth, p_instance);

    env->ReleaseStringUTFChars(sourceName, native_name);
    return (jlong)p_instance;
}

extern "C" JNIEXPORT void JNICALL
Java_com_antigravity_ndi_1player_1app_NdiView_destroyReceiver(JNIEnv* /* env */, jobject /* this */, jlong p_instance) {
    if (p_instance) {
        NDIlib_recv_destroy((NDIlib_recv_instance_t)p_instance);
        LOGD("destroyReceiver %p", (void*)p_instance);
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_antigravity_ndi_1player_1app_NdiView_captureFrame(
    JNIEnv* env, jobject /* this */, jlong p_instance, 
    jobject bitmap, jintArray outDim, jobjectArray outAudioHolder) {
    if (!p_instance) return 0;
    NDIlib_recv_instance_t recv = (NDIlib_recv_instance_t)p_instance;
    NDIlib_video_frame_v2_t video_frame;
    NDIlib_audio_frame_v2_t audio_frame;
    
    // Unified capture: capture video and audio together with 16ms timeout (~60fps)
    NDIlib_frame_type_e type = NDIlib_recv_capture_v2(recv, &video_frame, &audio_frame, nullptr, 16);

    if (type == NDIlib_frame_type_video) {
        AndroidBitmapInfo info;
        void* pixels = nullptr;
        if (AndroidBitmap_getInfo(env, bitmap, &info) < 0) {
            NDIlib_recv_free_video_v2(recv, &video_frame);
            return 0;
        }

        // If resolution mismatch, immediately output the new dimensions
        if (video_frame.xres != (int)info.width || video_frame.yres != (int)info.height) {
            jint dim[2] = { video_frame.xres, video_frame.yres };
            env->SetIntArrayRegion(outDim, 0, 2, dim);
            NDIlib_recv_free_video_v2(recv, &video_frame);
            return -1; // Resolution changed
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

        if (video_frame.FourCC == NDIlib_FourCC_video_type_UYVY) {
            auto clamp = [](int v) -> uint8_t { return (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v)); };
            for (int y = 0; y < height; y++) {
                const uint8_t* src_row = src_ptr + y * src_stride;
                uint32_t* dst_row = (uint32_t*)((uint8_t*)dst_ptr + y * dst_stride);
                for (int x = 0; x < width - 1; x += 2) {
                    int u  = (int)src_row[2*x] - 128;
                    int y0 = (int)src_row[2*x+1] - 16;
                    int v  = (int)src_row[2*x+2] - 128;
                    int y1 = (int)src_row[2*x+3] - 16;
                    
                    int r0 = (298 * y0 + 409 * v + 128) >> 8;
                    int g0 = (298 * y0 - 100 * u - 208 * v + 128) >> 8;
                    int b0 = (298 * y0 + 516 * u + 128) >> 8;
                    dst_row[x] = (0xFF << 24) | (clamp(r0) << 16) | (clamp(g0) << 8) | clamp(b0);

                    int r1 = (298 * y1 + 409 * v + 128) >> 8;
                    int g1 = (298 * y1 - 100 * u - 208 * v + 128) >> 8;
                    int b1 = (298 * y1 + 516 * u + 128) >> 8;
                    dst_row[x+1] = (0xFF << 24) | (clamp(r1) << 16) | (clamp(g1) << 8) | clamp(b1);
                }
            }
        } else if (video_frame.FourCC == NDIlib_FourCC_video_type_RGBA || video_frame.FourCC == NDIlib_FourCC_video_type_RGBX || 
                   video_frame.FourCC == NDIlib_FourCC_video_type_BGRA || video_frame.FourCC == NDIlib_FourCC_video_type_BGRX) {
            int copyBytes = std::min(dst_stride, width * 4);
            for (int y = 0; y < height; y++) {
                memcpy((uint8_t*)dst_ptr + y * dst_stride, src_ptr + y * src_stride, copyBytes);
            }
        }

        AndroidBitmap_unlockPixels(env, bitmap);
        NDIlib_recv_free_video_v2(recv, &video_frame);
        return 1; // Video frame captured
    } 
    else if (type == NDIlib_frame_type_audio) {
        int no_samples = audio_frame.no_samples;
        int no_channels = audio_frame.no_channels;
        
        if (no_samples > 0 && audio_frame.p_data && outAudioHolder) {
            jfloatArray audioArray = env->NewFloatArray(no_samples * 2);
            std::vector<float> interleaved(no_samples * 2);
            
            float* p_data = audio_frame.p_data;
            int channel_stride = audio_frame.channel_stride_in_bytes / sizeof(float);
            
            for (int s = 0; s < no_samples; s++) {
                interleaved[2 * s] = p_data[s]; // Left
                interleaved[2 * s + 1] = (no_channels > 1) ? p_data[channel_stride + s] : p_data[s]; // Right
            }
            
            env->SetFloatArrayRegion(audioArray, 0, no_samples * 2, interleaved.data());
            env->SetObjectArrayElement(outAudioHolder, 0, audioArray);
            env->DeleteLocalRef(audioArray);
        }
        
        NDIlib_recv_free_audio_v2(recv, &audio_frame);
        return 2; // Audio frame captured
    }

    return 0; // Timeout
}

// Fallback legacy signatures if needed
extern "C" JNIEXPORT jint JNICALL
Java_com_antigravity_ndi_1player_1app_NdiView_captureFrameToBitmap(JNIEnv* env, jobject thiz, jlong p_instance, jobject bitmap) {
    jintArray dim = env->NewIntArray(2);
    jclass floatArrClass = env->FindClass("[F");
    jobjectArray holder = env->NewObjectArray(1, floatArrClass, nullptr);
    jint res = Java_com_antigravity_ndi_1player_1app_NdiView_captureFrame(env, thiz, p_instance, bitmap, dim, holder);
    env->DeleteLocalRef(dim);
    env->DeleteLocalRef(holder);
    return res;
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_antigravity_ndi_1player_1app_NdiView_captureAudio(JNIEnv* env, jobject /* this */, jlong p_instance) {
    if (!p_instance) return nullptr;
    NDIlib_recv_instance_t recv = (NDIlib_recv_instance_t)p_instance;
    NDIlib_audio_frame_v2_t audio_frame;
    
    if (NDIlib_recv_capture_v2(recv, nullptr, &audio_frame, nullptr, 0) == NDIlib_frame_type_audio) {
        int no_samples = audio_frame.no_samples;
        int no_channels = audio_frame.no_channels;
        
        jfloatArray result = env->NewFloatArray(no_samples * 2);
        std::vector<float> interleaved(no_samples * 2);
        
        float* p_data = audio_frame.p_data;
        int channel_stride = audio_frame.channel_stride_in_bytes / sizeof(float);
        
        for (int s = 0; s < no_samples; s++) {
            interleaved[2 * s] = p_data[s];
            interleaved[2 * s + 1] = (no_channels > 1) ? p_data[channel_stride + s] : p_data[s];
        }
        
        env->SetFloatArrayRegion(result, 0, no_samples * 2, interleaved.data());
        NDIlib_recv_free_audio_v2(recv, &audio_frame);
        return result;
    }
    return nullptr;
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
