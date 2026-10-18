#include "gainmap_math.h"
#include "ultrahdr_api.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <jpeglib.h>

namespace {
struct Image {
  int w, h;
  std::vector<uint8_t> sdr;
  std::vector<float> hdr;
  std::vector<uint8_t> encoded;
  bool has_hdr = false;
  float headroom = 1;
  Image(int width, int height) : w(width), h(height), sdr(w * h * 4), hdr(w * h * 4) {}
};
std::string error;
bool valid_size(int w, int h) {
  if (w > 0 && h > 0 && w <= 8192 && h <= 8192 && int64_t(w) * h <= 16777216) return true;
  error = "Image exceeds the 16 megapixel working limit (maximum side 8192).";
  return false;
}
bool check(uhdr_error_info_t status) {
  if (status.error_code == UHDR_CODEC_OK) return true;
  error = status.has_detail ? status.detail : "Ultra HDR codec failed.";
  return false;
}
uint8_t byte(float v) { return uint8_t(std::clamp(std::lround(v * 255), 0l, 255l)); }
float half_to_float(uint16_t h) {
  const int sign = (h >> 15) ? -1 : 1;
  const int exponent = (h >> 10) & 31;
  const int mantissa = h & 1023;
  if (exponent == 31) return 0;
  return sign * std::ldexp(exponent ? 1 + mantissa / 1024.0f : mantissa / 1024.0f,
                           exponent ? exponent - 15 : -14);
}
uint16_t float_to_half(float v) {
  uint32_t bits;
  v = std::clamp(v, 0.0f, 65504.0f);
  std::memcpy(&bits, &v, 4);
  int exponent = int((bits >> 23) & 255) - 127 + 15;
  if (exponent <= 0) return exponent < -10 ? 0 : uint16_t(((bits & 0x7fffff) | 0x800000) >> (14 - exponent));
  return uint16_t((exponent << 10) | ((bits & 0x7fffff) >> 13));
}
void to_srgb(float* rgb, uhdr_color_gamut_t gamut) {
  const float r = rgb[0], g = rgb[1], b = rgb[2];
  if (gamut == UHDR_CG_DISPLAY_P3) {
    rgb[0] = 1.224745f*r - 0.224904f*g;
    rgb[1] = -0.042058f*r + 1.042081f*g;
    rgb[2] = -0.019642f*r - 0.078655f*g + 1.098537f*b;
  } else if (gamut == UHDR_CG_BT_2100) {
    rgb[0] = 1.660491f*r - 0.587641f*g - 0.072850f*b;
    rgb[1] = -0.124550f*r + 1.132900f*g - 0.008349f*b;
    rgb[2] = -0.018151f*r - 0.100579f*g + 1.118730f*b;
  }
  for (int c = 0; c < 3; ++c) rgb[c] = std::max(0.0f, rgb[c]);
}
int orientation(const uhdr_mem_block_t* exif) {
  if (!exif || exif->data_sz < 14) return 1;
  auto p = static_cast<const uint8_t*>(exif->data);
  size_t n = exif->data_sz;
  if (std::memcmp(p, "Exif\0\0", 6) == 0) { p += 6; n -= 6; }
  const bool le = p[0] == 'I' && p[1] == 'I';
  auto read = [&](size_t pos, int size) -> uint32_t {
    if (pos + size > n) return 0;
    uint32_t v = 0;
    for (int i = 0; i < size; ++i) v |= uint32_t(p[pos+i]) << (8 * (le ? i : size-1-i));
    return v;
  };
  size_t off = read(4, 4);
  if (off + 2 > n) return 1;
  int count = std::min(read(off, 2), uint32_t(512));
  for (int i = 0; i < count; ++i) {
    size_t at = off + 2 + i * 12;
    if (at + 12 > n) break;
    if (read(at, 2) == 0x112 && read(at+2, 2) == 3 && read(at+4, 4) == 1) {
      int v = read(at+8, 2);
      return v >= 1 && v <= 8 ? v : 1;
    }
  }
  return 1;
}
Image* orient(Image* source, int value) {
  if (value == 1) return source;
  auto result = new Image(value >= 5 ? source->h : source->w, value >= 5 ? source->w : source->h);
  result->has_hdr = source->has_hdr;
  result->headroom = source->headroom;
  for (int y = 0; y < source->h; ++y) for (int x = 0; x < source->w; ++x) {
    int dx = x, dy = y;
    switch (value) {
      case 2: dx = source->w-1-x; break;
      case 3: dx = source->w-1-x; dy = source->h-1-y; break;
      case 4: dy = source->h-1-y; break;
      case 5: dx = y; dy = x; break;
      case 6: dx = source->h-1-y; dy = x; break;
      case 7: dx = source->h-1-y; dy = source->w-1-x; break;
      case 8: dx = y; dy = source->w-1-x; break;
    }
    for (int c = 0; c < 4; ++c) {
      result->sdr[(dy*result->w+dx)*4+c] = source->sdr[(y*source->w+x)*4+c];
      result->hdr[(dy*result->w+dx)*4+c] = source->hdr[(y*source->w+x)*4+c];
    }
  }
  delete source;
  return result;
}
}

extern "C" {
const char* ps_error() { return error.c_str(); }
int ps_is_hdr(uint8_t* bytes, int size) { return size > 0 && is_uhdr_image(bytes, size); }
void ps_destroy(Image* image) { delete image; }
Image* ps_clone(Image* source) {
  if (!source) return nullptr;
  auto result = new Image(source->w, source->h);
  result->sdr = source->sdr; result->hdr = source->hdr;
  result->has_hdr = source->has_hdr; result->headroom = source->headroom;
  return result;
}
int ps_width(Image* image) { return image ? image->w : 0; }
int ps_height(Image* image) { return image ? image->h : 0; }
float ps_sample(Image* image, int x, int y, int channel) {
  if (!image || x < 0 || y < 0 || x >= image->w || y >= image->h || channel < 0 || channel > 3) return -1;
  return image->hdr[(y*image->w+x)*4+channel];
}
uint8_t* ps_pixels(Image* image) { return image ? image->sdr.data() : nullptr; }
uint8_t* ps_data(Image* image) { return image ? image->encoded.data() : nullptr; }
int ps_size(Image* image) { return image ? int(image->encoded.size()) : 0; }

Image* ps_decode(uint8_t* bytes, int size, int max_side) {
  error.clear();
  auto dec = std::unique_ptr<uhdr_codec_private_t, decltype(&uhdr_release_decoder)>(uhdr_create_decoder(), uhdr_release_decoder);
  uhdr_compressed_image_t input{bytes, size_t(size), size_t(size), UHDR_CG_UNSPECIFIED, UHDR_CT_UNSPECIFIED, UHDR_CR_UNSPECIFIED};
  if (!dec || !check(uhdr_dec_set_image(dec.get(), &input)) || !check(uhdr_dec_probe(dec.get()))) return nullptr;
  const int rotation = orientation(uhdr_dec_get_exif(dec.get()));
  int w = uhdr_dec_get_image_width(dec.get()), h = uhdr_dec_get_image_height(dec.get());
  if (max_side > 0 && std::max(w, h) > max_side) {
    float scale = float(max_side) / std::max(w, h);
    w = std::max(2, int(w*scale)); h = std::max(2, int(h*scale));
  }
  if (!valid_size(w, h)) return nullptr;
  auto result = std::make_unique<Image>(w, h);
  const auto metadata = uhdr_dec_get_gainmap_metadata(dec.get());
  result->headroom = metadata ? metadata->hdr_capacity_max : 1;
  for (int pass = 0; pass < 2; ++pass) {
    // v1.4 locks output configuration at probe, before the first decode.
    uhdr_reset_decoder(dec.get());
    if (!check(uhdr_dec_set_image(dec.get(), &input))) return nullptr;
    if (!check(uhdr_dec_set_out_img_format(dec.get(), pass ? UHDR_IMG_FMT_64bppRGBAHalfFloat : UHDR_IMG_FMT_32bppRGBA8888)) ||
        !check(uhdr_dec_set_out_color_transfer(dec.get(), pass ? UHDR_CT_LINEAR : UHDR_CT_SRGB)) ||
        !check(uhdr_add_effect_resize(dec.get(), w, h)) || !check(uhdr_decode(dec.get()))) return nullptr;
    auto raw = uhdr_get_decoded_image(dec.get());
    if (!raw) { error = "Decoder returned no pixels."; return nullptr; }
    for (int y = 0; y < h; ++y) for (int x = 0; x < w; ++x) {
      float rgb[3];
      for (int c = 0; c < 3; ++c) {
        size_t at = (y * raw->stride[0] + x) * 4 + c;
        rgb[c] = pass ? half_to_float(static_cast<uint16_t*>(raw->planes[0])[at]) :
          poststudio::srgb_to_linear(static_cast<uint8_t*>(raw->planes[0])[at] / 255.0f);
      }
      to_srgb(rgb, raw->cg);
      for (int c = 0; c < 3; ++c) {
        if (pass) result->hdr[(y*w+x)*4+c] = rgb[c];
        else result->sdr[(y*w+x)*4+c] = byte(poststudio::linear_to_srgb(rgb[c]));
      }
      result->hdr[(y*w+x)*4+3] = 1;
      result->sdr[(y*w+x)*4+3] = 255;
    }
  }
  result->has_hdr = true;
  return orient(result.release(), rotation);
}

Image* ps_rgba(uint8_t* bytes, int w, int h) {
  if (!bytes || !valid_size(w, h)) return nullptr;
  auto result = new Image(w, h);
  std::memcpy(result->sdr.data(), bytes, w*h*4);
  for (int i = 0; i < w*h*4; ++i)
    result->hdr[i] = i%4 == 3 ? bytes[i]/255.0f : poststudio::srgb_to_linear(bytes[i]/255.0f);
  return result;
}

Image* ps_page(int w, int h, uint32_t background, float gain) {
  if (!valid_size(w, h)) return nullptr;
  auto result = new Image(w, h);
  const uint8_t rgba[4] = {uint8_t(background>>16), uint8_t(background>>8), uint8_t(background), 255};
  for (int i = 0; i < w*h; ++i) for (int c = 0; c < 4; ++c) {
    result->sdr[i*4+c] = rgba[c];
    result->hdr[i*4+c] = c == 3 ? 1 : poststudio::srgb_to_linear(rgba[c]/255.0f)*gain;
  }
  result->has_hdr = gain > 1;
  result->headroom = std::max(1.0f, gain);
  return result;
}

void ps_adjust(Image* image, float* matrix, float highlights, float shadows, float brightness, int enhanced) {
  if (!image) return;
  if (!matrix && highlights == 0 && shadows == 0 && brightness == 1 && !enhanced) return;
  const bool original_hdr = image->has_hdr;
  const float peak = std::max(brightness, enhanced ? 2.0f : 1.0f);
  for (int i = 0; i < image->w*image->h; ++i) {
    float rgb[3], gain[3];
    for (int c = 0; c < 3; ++c) {
      rgb[c] = image->sdr[i*4+c]/255.0f;
      const float base = poststudio::srgb_to_linear(rgb[c]);
      gain[c] = original_hdr ? std::pow(std::max(1.0f/64, (image->hdr[i*4+c]+1.0f/64)/(base+1.0f/64)), std::max(0.0f, brightness)) : 1;
    }
    float luma = std::floor((rgb[0]*0.2126f + rgb[1]*0.7152f + rgb[2]*0.0722f)*255)/255;
    float factor = std::clamp(1 + highlights*0.6f*luma*luma + shadows*0.6f*(1-luma)*(1-luma), 0.0f, 4.0f);
    float tone[3];
    for (int c = 0; c < 3; ++c) tone[c] = std::clamp(std::floor(rgb[c]*255*factor), 0.0f, 255.0f);
    for (int c = 0; c < 3; ++c) {
      rgb[c] = matrix ? std::clamp((matrix[c*5]*tone[0]+matrix[c*5+1]*tone[1]+matrix[c*5+2]*tone[2]+matrix[c*5+3]*image->sdr[i*4+3]+matrix[c*5+4])/255, 0.0f, 1.0f) : tone[c]/255;
      image->sdr[i*4+c] = byte(rgb[c]);
    }
    luma = rgb[0]*0.2126f+rgb[1]*0.7152f+rgb[2]*0.0722f;
    for (int c = 0; c < 3; ++c) {
      if (!original_hdr) gain[c] = poststudio::highlight_gain(luma, peak);
      image->hdr[i*4+c] = std::max(0.0f, (poststudio::srgb_to_linear(rgb[c])+1.0f/64)*gain[c]-1.0f/64);
    }
  }
  image->has_hdr = original_hdr ? brightness > 0 : peak > 1;
  if (!original_hdr) image->headroom = peak;
}

void ps_draw(Image* dest, Image* source, float dx, float dy, float dw, float dh,
             float sx, float sy, float sw, float sh, float radius) {
  if (!dest || !source || dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0) return;
  radius = std::clamp(radius, 0.0f, std::min(dw, dh)*0.5f);
  int x0 = std::max(0, int(std::floor(dx))), y0 = std::max(0, int(std::floor(dy)));
  int x1 = std::min(dest->w, int(std::ceil(dx+dw))), y1 = std::min(dest->h, int(std::ceil(dy+dh)));
  for (int y = y0; y < y1; ++y) for (int x = x0; x < x1; ++x) {
    float edge = 1;
    if (radius > 0) {
      const float px = std::abs(x+0.5f-dx-dw*0.5f)-(dw*0.5f-radius);
      const float py = std::abs(y+0.5f-dy-dh*0.5f)-(dh*0.5f-radius);
      const float distance = std::hypot(std::max(0.0f,px),std::max(0.0f,py))+std::min(std::max(px,py),0.0f)-radius;
      edge = std::clamp(0.5f-distance,0.0f,1.0f);
      if (edge == 0) continue;
    }
    float fx = std::clamp(sx+(x+0.5f-dx)/dw*sw-0.5f,0.0f,float(source->w-1));
    float fy = std::clamp(sy+(y+0.5f-dy)/dh*sh-0.5f,0.0f,float(source->h-1));
    int ix = int(fx), iy = int(fy), jx = std::min(ix+1,source->w-1), jy = std::min(iy+1,source->h-1);
    const float tx = fx-ix, ty = fy-iy;
    const int pos[4] = {(iy*source->w+ix)*4,(iy*source->w+jx)*4,(jy*source->w+ix)*4,(jy*source->w+jx)*4};
    const float weights[4] = {(1-tx)*(1-ty),tx*(1-ty),(1-tx)*ty,tx*ty};
    float alpha = 0, sdr[3]{}, hdr[3]{};
    for (int p=0;p<4;++p) {
      const float a = source->sdr[pos[p]+3]/255.0f * weights[p] * edge;
      alpha += a;
      for (int c=0;c<3;++c) { sdr[c] += source->sdr[pos[p]+c]/255.0f*a; hdr[c] += source->hdr[pos[p]+c]*a; }
    }
    const int at = (y*dest->w+x)*4;
    for (int c=0;c<3;++c) {
      dest->sdr[at+c] = byte(sdr[c]+dest->sdr[at+c]/255.0f*(1-alpha));
      dest->hdr[at+c] = hdr[c]+dest->hdr[at+c]*(1-alpha);
    }
  }
  dest->has_hdr |= source->has_hdr;
  dest->headroom = std::max(dest->headroom, source->headroom);
}

Image* ps_resize(Image* source, int max_side) {
  if (!source || max_side <= 0) return nullptr;
  float scale = std::min(1.0f,float(max_side)/std::max(source->w,source->h));
  auto result = ps_page(std::max(1,int(source->w*scale)),std::max(1,int(source->h*scale)),0,1);
  ps_draw(result,source,0,0,result->w,result->h,0,0,source->w,source->h,0);
  return result;
}

int encode_image(Image* image, int hdr, int quality, int gainmap_scale) {
  if (!image) return 0;
  image->encoded.clear();
  if (!hdr || !image->has_hdr) {
    jpeg_compress_struct compressor{};
    jpeg_error_mgr manager{};
    compressor.err = jpeg_std_error(&manager);
    jpeg_create_compress(&compressor);
    unsigned char* memory = nullptr; unsigned long size = 0;
    jpeg_mem_dest(&compressor,&memory,&size);
    compressor.image_width=image->w; compressor.image_height=image->h;
    compressor.input_components=3; compressor.in_color_space=JCS_RGB;
    jpeg_set_defaults(&compressor); jpeg_set_quality(&compressor,quality,TRUE);
    jpeg_start_compress(&compressor,TRUE);
    std::vector<uint8_t> row(image->w*3);
    while (compressor.next_scanline < unsigned(image->h)) {
      for (int x=0;x<image->w;++x) for (int c=0;c<3;++c)
        row[x*3+c]=image->sdr[(compressor.next_scanline*image->w+x)*4+c];
      JSAMPROW pointer=row.data(); jpeg_write_scanlines(&compressor,&pointer,1);
    }
    jpeg_finish_compress(&compressor);
    image->encoded.assign(memory,memory+size); std::free(memory);
    jpeg_destroy_compress(&compressor); return 1;
  }
  std::vector<uint16_t> pixels(image->hdr.size());
  std::transform(image->hdr.begin(),image->hdr.end(),pixels.begin(),float_to_half);
  uhdr_raw_image_t hdr_image{};
  hdr_image.fmt=UHDR_IMG_FMT_64bppRGBAHalfFloat; hdr_image.cg=UHDR_CG_BT_709;
  hdr_image.ct=UHDR_CT_LINEAR; hdr_image.range=UHDR_CR_FULL_RANGE;
  hdr_image.w=image->w; hdr_image.h=image->h; hdr_image.planes[0]=pixels.data(); hdr_image.stride[0]=image->w;
  uhdr_raw_image_t sdr_image=hdr_image;
  sdr_image.fmt=UHDR_IMG_FMT_32bppRGBA8888; sdr_image.ct=UHDR_CT_SRGB; sdr_image.planes[0]=image->sdr.data();
  auto enc=std::unique_ptr<uhdr_codec_private_t,decltype(&uhdr_release_encoder)>(uhdr_create_encoder(),uhdr_release_encoder);
  if (!enc || !check(uhdr_enc_set_raw_image(enc.get(),&hdr_image,UHDR_HDR_IMG)) ||
      !check(uhdr_enc_set_raw_image(enc.get(),&sdr_image,UHDR_SDR_IMG)) ||
      !check(uhdr_enc_set_quality(enc.get(),quality,UHDR_BASE_IMG)) ||
      !check(uhdr_enc_set_quality(enc.get(),100,UHDR_GAIN_MAP_IMG)) ||
      !check(uhdr_enc_set_using_multi_channel_gainmap(enc.get(),0)) ||
      !check(uhdr_enc_set_target_display_peak_brightness(enc.get(), std::clamp(image->headroom * 203, 203.01f, 10000.0f))) ||
      !check(uhdr_enc_set_gainmap_scale_factor(enc.get(),gainmap_scale)) || !check(uhdr_encode(enc.get()))) return 0;
  auto encoded=uhdr_get_encoded_stream(enc.get());
  if (!encoded) { error="Encoder returned no output."; return 0; }
  auto data=static_cast<uint8_t*>(encoded->data);
  image->encoded.assign(data,data+encoded->data_sz); return 1;
}
int ps_encode(Image* image, int hdr) { return encode_image(image, hdr, 100, 1); }
int ps_encode_preview(Image* image, int hdr) {
  return encode_image(image, hdr, 90, std::min(image->w, image->h) >= 8 ? 4 : 1);
}
}
