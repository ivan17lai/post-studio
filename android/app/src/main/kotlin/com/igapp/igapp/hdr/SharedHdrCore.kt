package com.igapp.igapp.hdr

/** Same C++ gain-map math as the browser's WebAssembly image core. */
internal object SharedHdrCore {
    init {
        System.loadLibrary("poststudio_hdr")
    }

    external fun gainLut(
        minimum: Float,
        maximum: Float,
        sourceMinimum: Float,
        sourceMaximum: Float,
        gamma: Float,
        brightness: Float,
    ): IntArray

    external fun synthesisLut(minimum: Float, maximum: Float, peak: Float): IntArray
}
