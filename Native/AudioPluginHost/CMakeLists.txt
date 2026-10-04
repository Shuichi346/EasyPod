cmake_minimum_required(VERSION 3.25)
project(EasyPodAudioPluginHost LANGUAGES C CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET 26.0 CACHE STRING "" FORCE)
get_filename_component(REPOSITORY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../.." ABSOLUTE)
if(NOT IS_ABSOLUTE "${VST3_SDK_ROOT}")
  get_filename_component(VST3_SDK_ROOT "${REPOSITORY_ROOT}/${VST3_SDK_ROOT}" ABSOLUTE)
endif()
if(NOT EXISTS "${VST3_SDK_ROOT}/public.sdk/source/vst/hosting/module.h")
  message(FATAL_ERROR "The pinned VST3 SDK and required submodules are missing. See SDK-PIN.md.")
endif()
set(SMTG_ENABLE_VST3_PLUGIN_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SMTG_ENABLE_VST3_HOSTING_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SMTG_ENABLE_VSTGUI_SUPPORT OFF CACHE BOOL "" FORCE)
set(SMTG_ENABLE_AUV2_BUILDS OFF CACHE BOOL "" FORCE)
add_subdirectory("${VST3_SDK_ROOT}" "${CMAKE_BINARY_DIR}/sdk" EXCLUDE_FROM_ALL)
add_library(AudioPluginHost STATIC
  AudioPluginHost.mm
  "${VST3_SDK_ROOT}/public.sdk/source/common/memorystream.cpp"
  "${VST3_SDK_ROOT}/public.sdk/source/vst/hosting/module_mac.mm"
  "${VST3_SDK_ROOT}/public.sdk/source/vst/hosting/plugprovider.cpp")
target_compile_options(AudioPluginHost PRIVATE -fobjc-arc)
target_compile_definitions(AudioPluginHost PRIVATE RELEASE=1)
target_include_directories(AudioPluginHost PRIVATE "${VST3_SDK_ROOT}")
target_link_libraries(AudioPluginHost PRIVATE sdk_hosting "-framework Cocoa" "-framework AVFoundation" "-framework AudioToolbox")
# Xcode consumes one archive; flatten the SDK dependencies into that archive.
add_custom_command(TARGET AudioPluginHost POST_BUILD
  COMMAND /usr/bin/libtool -static -o "${CMAKE_BINARY_DIR}/libAudioPluginHost-combined.a"
    "$<TARGET_FILE:AudioPluginHost>" "$<TARGET_FILE:sdk_hosting>"
    "$<TARGET_FILE:sdk_common>" "$<TARGET_FILE:base>" "$<TARGET_FILE:pluginterfaces>"
  COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_BINARY_DIR}/libAudioPluginHost-combined.a" "$<TARGET_FILE:AudioPluginHost>")
add_executable(EasyPodPluginScanner PluginScanner.mm)
target_compile_options(EasyPodPluginScanner PRIVATE -fobjc-arc)
target_link_libraries(EasyPodPluginScanner PRIVATE AudioPluginHost "-framework Cocoa" "-framework AVFoundation" "-framework AudioToolbox")
