#include "whisper.h"
#include "common-whisper.h"
#include "json.hpp"
#include <algorithm>
#include <cmath>
#include <iostream>
#include <memory>
#include <string>
#include <vector>
using json = nlohmann::ordered_json;
static void quiet_log(enum ggml_log_level, const char *, void *) {}
static void reply(const json & value) { std::cout << value.dump() << '\n' << std::flush; }
int main(int argc, char ** argv) {
    if (argc != 2) return 2;
    whisper_log_set(quiet_log, nullptr);
    ggml_log_set(quiet_log, nullptr);
    auto params = whisper_context_default_params();
    std::unique_ptr<whisper_context, decltype(&whisper_free)> context(
        whisper_init_from_file_with_params(argv[1], params), whisper_free);
    if (!context) { reply({{"ready", false}, {"error", "model_load"}}); return 3; }
    reply({{"ready", true}, {"protocol", 1}});
    std::string line;
    while (std::getline(std::cin, line)) {
        std::string id;
        try {
            if (line.size() > 65536) throw std::runtime_error("request_size");
            auto request = json::parse(line);
            id = request.at("id").get<std::string>();
            const auto file = request.at("audio").get<std::string>();
            const auto language = request.value("language", std::string("auto"));
            const auto prompt = request.value("dictionary", std::string());
            if (language != "auto" && whisper_lang_id(language.c_str()) < 0) {
                reply({{"id", id}, {"error", "language"}}); continue;
            }
            std::vector<float> samples;
            std::vector<std::vector<float>> channels;
            if (!read_audio_data(file, samples, channels, false)) {
                reply({{"id", id}, {"error", "audio_read"}}); continue;
            }
            if (samples.size() > 121 * WHISPER_SAMPLE_RATE) {
                reply({{"id", id}, {"error", "audio_duration"}}); continue;
            }
            const bool signal = std::any_of(samples.begin(), samples.end(), [](float x) {
                return std::isfinite(x) && std::abs(x) > 0.0001f;
            });
            if (!signal) { reply({{"id", id}, {"text", ""}}); continue; }
            auto settings = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
            settings.n_threads = 4;
            settings.beam_search.beam_size = 5;
            settings.print_realtime = false;
            settings.print_progress = false;
            settings.print_timestamps = false;
            settings.print_special = false;
            settings.no_timestamps = true;
            // Every segment has its own explicit context; never reuse another session's tokens.
            settings.no_context = true;
            settings.language = language.c_str();
            settings.initial_prompt = prompt.c_str();
            settings.translate = false;
            if (whisper_full(context.get(), settings, samples.data(), int(samples.size())) != 0) {
                reply({{"id", id}, {"error", "inference"}}); continue;
            }
            std::string result;
            const int count = whisper_full_n_segments(context.get());
            for (int i = 0; i < count; ++i) result += whisper_full_get_segment_text(context.get(), i);
            reply({{"id", id}, {"text", result}});
        } catch (...) { reply({{"id", id}, {"error", "invalid_request"}}); }
    }
    return 0;
}
