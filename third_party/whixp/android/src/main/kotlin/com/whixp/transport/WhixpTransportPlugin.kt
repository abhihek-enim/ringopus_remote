package com.whixp.transport

import io.flutter.embedding.engine.plugins.FlutterPlugin

/** Stub plugin so Flutter recognizes the platform. Native lib is loaded via Dart FFI from jniLibs. */
class WhixpTransportPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
