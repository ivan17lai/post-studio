#include "gainmap_math.h"
#include <algorithm>
#include <cmath>

namespace poststudio {
uint8_t encode_gain(float value, float minimum, float maximum) {
  const float lo = std::log2(std::max(minimum, 1.0f / 64));
  const float hi = std::log2(std::max(maximum, 1.0f / 64));
  if (hi <= lo || !std::isfinite(value)) return 0;
  return static_cast<uint8_t>(std::clamp(std::lround((value - lo) / (hi - lo) * 255), 0l, 255l));
}
void gain_lut(float minimum, float maximum, float source_minimum,
              float source_maximum, float gamma, float brightness, int32_t* out) {
  const float lo = std::log2(std::max(source_minimum, 1.0f / 64));
  const float hi = std::log2(std::max(source_maximum, 1.0f / 64));
  for (int i = 0; i < 256; ++i) {
    const float t = std::pow(i / 255.0f, gamma > 0 ? gamma : 1.0f);
    out[i] = encode_gain(brightness * (lo + t * (hi - lo)), minimum, maximum);
  }
}
float highlight_gain(float luminance, float maximum) {
  const float t = std::clamp((luminance - 0.6f) / 0.4f, 0.0f, 1.0f);
  return std::pow(std::max(1.0f, maximum), t * t * (3 - 2 * t));
}
float srgb_to_linear(float v) {
  return v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f);
}
float linear_to_srgb(float v) {
  return v <= 0.0031308f ? v * 12.92f : 1.055f * std::pow(v, 1 / 2.4f) - 0.055f;
}
}
