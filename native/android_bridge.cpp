#include <jni.h>
#include <cmath>
#include "gainmap_math.h"

extern "C" JNIEXPORT jintArray JNICALL
Java_com_igapp_igapp_hdr_SharedHdrCore_gainLut(
    JNIEnv* env, jobject, jfloat minimum, jfloat maximum, jfloat source_minimum,
    jfloat source_maximum, jfloat gamma, jfloat brightness) {
  int32_t values[256];
  poststudio::gain_lut(minimum, maximum, source_minimum, source_maximum, gamma, brightness, values);
  auto result = env->NewIntArray(256);
  if (result) env->SetIntArrayRegion(result, 0, 256, values);
  return result;
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_igapp_igapp_hdr_SharedHdrCore_synthesisLut(
    JNIEnv* env, jobject, jfloat minimum, jfloat maximum, jfloat peak) {
  int32_t values[256];
  for (int i = 0; i < 256; ++i) {
    const float gain = poststudio::highlight_gain(i / 255.0f, peak);
    values[i] = poststudio::encode_gain(std::log2(gain), minimum, maximum);
  }
  auto result = env->NewIntArray(256);
  if (result) env->SetIntArrayRegion(result, 0, 256, values);
  return result;
}
