/*
 * Copyright (c) 2026 CasparCG Contributors
 *
 * StereoTool audio processor wrapper with dynamic library loading.
 * Uses dlopen/dlsym to load libStereoTool at runtime, avoiding a
 * build-time dependency. CasparCG works normally without the library.
 *
 * StereoTool is a product of Thimeo Audio Technology B.V.
 * See https://www.thimeo.com/stereo-tool/
 */

#pragma once

#include <common/except.h>
#include <common/log.h>

#include <algorithm>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

namespace caspar { namespace core {

class stereotool_processor
{
  public:
    static constexpr int LOAD_ALL_SETTINGS = 10386; // ID_SAVE_ALLSETTINGS from ParameterEnum.h

    stereotool_processor(const std::string& library_path, const std::string& license_key = "")
    {
        auto& lib = shared_library(library_path);
        fn_create3_         = lib.resolve<create3_fn>("stereoTool_Create3");
        fn_delete_          = lib.resolve<delete_fn>("stereoTool_Delete");
        fn_process_         = lib.resolve<process_fn>("stereoTool_Process");
        fn_load_preset_     = lib.resolve<load_preset_fn>("stereoTool_LoadPreset");
        fn_get_latency2_    = lib.resolve<get_latency2_fn>("stereoTool_GetLatency2");
        fn_get_api_version_ = lib.resolve<get_api_ver_fn>("stereoTool_GetApiVersion");

        auto key_ptr = license_key.empty() ? nullptr : license_key.c_str();
        instance_    = fn_create3_(false, key_ptr, nullptr, nullptr, false);
        if (!instance_) {
            CASPAR_THROW_EXCEPTION(caspar_exception() << msg_info("Failed to create StereoTool instance"));
        }

        CASPAR_LOG(info) << "[stereotool] Created instance (API version " << fn_get_api_version_() << ")";
    }

    ~stereotool_processor()
    {
        if (instance_ && fn_delete_) {
            fn_delete_(instance_);
            instance_ = nullptr;
        }
    }

    stereotool_processor(const stereotool_processor&)            = delete;
    stereotool_processor& operator=(const stereotool_processor&) = delete;

    bool load_preset(const std::string& path, int loadsave_type = LOAD_ALL_SETTINGS)
    {
        auto result = fn_load_preset_(instance_, path.c_str(), loadsave_type);
        if (result) {
            CASPAR_LOG(info) << "[stereotool] Loaded preset: " << path;
        } else {
            CASPAR_LOG(error) << "[stereotool] Failed to load preset: " << path;
        }
        return result;
    }

    int get_latency(int samplerate) { return fn_get_latency2_(instance_, samplerate, true); }

    void process(int32_t* interleaved_data, int nb_samples, int total_channels, int samplerate)
    {
        if (total_channels < 2 || nb_samples <= 0)
            return;

        const int stereo_channels = 2;

        if (static_cast<int>(float_buf_.size()) < nb_samples * stereo_channels)
            float_buf_.resize(nb_samples * stereo_channels);

        for (int i = 0; i < nb_samples; ++i) {
            float_buf_[i * 2 + 0] = interleaved_data[i * total_channels + 0] / 2147483648.0f;
            float_buf_[i * 2 + 1] = interleaved_data[i * total_channels + 1] / 2147483648.0f;
        }

        fn_process_(instance_, float_buf_.data(), nb_samples, stereo_channels, samplerate);

        for (int i = 0; i < nb_samples; ++i) {
            float l = std::clamp(float_buf_[i * 2 + 0], -1.0f, 1.0f);
            float r = std::clamp(float_buf_[i * 2 + 1], -1.0f, 1.0f);
            interleaved_data[i * total_channels + 0] = static_cast<int32_t>(l * 2147483647.0f);
            interleaved_data[i * total_channels + 1] = static_cast<int32_t>(r * 2147483647.0f);
        }
    }

  private:
    using create3_fn      = void* (*)(bool, const char*, const char*, const char*, bool);
    using delete_fn       = void (*)(void*);
    using process_fn      = void (*)(void*, float*, int32_t, int32_t, int32_t);
    using load_preset_fn  = bool (*)(void*, const char*, int);
    using get_latency2_fn = int (*)(void*, int32_t, bool);
    using get_api_ver_fn  = int (*)();

    void* instance_ = nullptr;

    create3_fn      fn_create3_          = nullptr;
    delete_fn       fn_delete_           = nullptr;
    process_fn      fn_process_          = nullptr;
    load_preset_fn  fn_load_preset_      = nullptr;
    get_latency2_fn fn_get_latency2_     = nullptr;
    get_api_ver_fn  fn_get_api_version_  = nullptr;

    std::vector<float> float_buf_;

    // Library handle kept alive for the process lifetime.
    // StereoTool has internal threads and global state that corrupt the heap
    // if the library is unloaded (dlclose) and reloaded.
    struct lib_handle
    {
#ifdef _WIN32
        HMODULE handle_ = nullptr;

        explicit lib_handle(const std::string& path)
        {
            handle_ = LoadLibraryA(path.c_str());
            if (!handle_)
                CASPAR_THROW_EXCEPTION(file_not_found()
                                       << msg_info("Failed to load StereoTool library: " + path));
        }

        template <typename T>
        T resolve(const char* name)
        {
            auto ptr = reinterpret_cast<T>(GetProcAddress(handle_, name));
            if (!ptr)
                CASPAR_THROW_EXCEPTION(caspar_exception()
                                       << msg_info(std::string("Symbol not found: ") + name));
            return ptr;
        }
#else
        void* handle_ = nullptr;

        explicit lib_handle(const std::string& path)
        {
            handle_ = dlopen(path.c_str(), RTLD_NOW);
            if (!handle_)
                CASPAR_THROW_EXCEPTION(file_not_found()
                                       << msg_info("Failed to load StereoTool library: " + path
                                                   + " (" + dlerror() + ")"));
        }

        template <typename T>
        T resolve(const char* name)
        {
            dlerror();
            auto ptr = reinterpret_cast<T>(dlsym(handle_, name));
            auto err = dlerror();
            if (err)
                CASPAR_THROW_EXCEPTION(caspar_exception()
                                       << msg_info(std::string("Symbol not found: ") + name
                                                   + " (" + err + ")"));
            return ptr;
        }
#endif
        ~lib_handle() = default; // intentionally never unload
    };

    static lib_handle& shared_library(const std::string& path)
    {
        static std::mutex              mtx;
        static std::unique_ptr<lib_handle> inst;
        std::lock_guard<std::mutex>    lock(mtx);
        if (!inst) {
            inst = std::make_unique<lib_handle>(path);
        }
        return *inst;
    }
};

}} // namespace caspar::core
