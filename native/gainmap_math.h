#pragma once
#include <cstdint>

namespace poststudio {
uint8_t encode_gain(float log_gain, float minimum, float maximum);
void gain_lut(float minimum, float maximum, float source_minimum,
              float source_maximum, float gamma, float brightness, int32_t* out);
float highlight_gain(float luminance, float maximum);
float srgb_to_linear(float value);
float linear_to_srgb(float value);
}
