#include "gainmap_math.h"
#include <cassert>
#include <cmath>
#include <iostream>
int main() {
  int32_t lut[256];
  poststudio::gain_lut(1,4,1,4,1,1,lut);
  for(int i=0;i<256;++i) assert(lut[i]==i);
  poststudio::gain_lut(0.25f,4,0.25f,4,1,0,lut);
  for(int i=0;i<256;++i) assert(lut[i]==128);
  poststudio::gain_lut(1,16,1,4,1,2,lut);
  assert(lut[0]==0 && lut[255]==255);
  assert(std::abs(poststudio::highlight_gain(1,4)-4)<0.0001);
  assert(poststudio::highlight_gain(0.5f,4)==1);
  for(int i=0;i<=255;++i) {
    float v=i/255.0f;
    assert(std::abs(poststudio::linear_to_srgb(poststudio::srgb_to_linear(v))-v)<0.00001);
  }
  std::cout << "Gain-map neutrality, brightness, highlights and color transfer passed.\n";
}
