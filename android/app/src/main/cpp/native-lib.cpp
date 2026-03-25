#include <jni.h>
#include <string>
#include <vector>
#include "Processing.NDI.Lib.h"

extern "C" JNIEXPORT jobject JNICALL
Java_com_antigravity_ndi_1player_1app_MainActivity_getNativeSources(JNIEnv* env, jobject /* this */) {
    if (!NDIlib_initialize()) return nullptr;

    NDIlib_find_create_t find_create_settings;
    NDIlib_find_instance_t p_find = NDIlib_find_create_v2(&find_create_settings);
    if (!p_find) return nullptr;

    // Wait for sources
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

extern "C" JNIEXPORT void JNICALL
Java_com_antigravity_ndi_1player_1app_MainActivity_connectToNativeSource(JNIEnv* env, jobject /* this */, jstring name) {
    const char* native_name = env->GetStringUTFChars(name, nullptr);
    
    // NDI connection logic here (NDIlib_recv_create_v3, etc.)
    // For now, this is just a bridge placeholder
    
    env->ReleaseStringUTFChars(name, native_name);
}
