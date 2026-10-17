#!/usr/bin/env python3
"""Generate the private, pinned Whisper source; never edit the upstream checkout."""
import hashlib
import pathlib
import sys

EXPECTED_SHA256 = "891168a838301bd2baa5e8b87422a854dafeeb7da914d40a2e4c6bf33ff448ed"


def prepare(source: bytes) -> str:
    if hashlib.sha256(source).hexdigest() != EXPECTED_SHA256:
        raise ValueError("Unsupported whisper.cpp source: review the encoder reuse patch before rebuilding")
    text = source.decode()
    replacements = [
        ("    // auto-detect language if not specified\n",
         "    // LightVoice: reuse only this call's language-detection encoder output.\n"
         "    // Detection decodes one token, but does not modify cross-attention KV.\n"
         "    bool language_encoder_ready = false;\n"
         "    int language_encoder_audio_ctx = 0;\n\n"
         "    // auto-detect language if not specified\n"),
        ("        params.language = whisper_lang_str(lang_id);\n",
         "        params.language = whisper_lang_str(lang_id);\n"
         "        language_encoder_ready = true;\n"
         "        language_encoder_audio_ctx = state->exp_n_audio_ctx;\n"),
        ("        // encode audio features starting at offset seek\n"
         "        if (!whisper_encode_internal(*ctx, *state, seek, params.n_threads, params.abort_callback, params.abort_callback_user_data)) {\n",
         "        // Consume once, only at the identical offset and audio context. Callbacks\n"
         "        // may mutate state, so preserve the original encoder path when present.\n"
         "        const bool reuse_language_encoder = language_encoder_ready && seek == 0 &&\n"
         "            language_encoder_audio_ctx == state->exp_n_audio_ctx &&\n"
         "            !params.encoder_begin_callback && !params.progress_callback;\n"
         "        language_encoder_ready = false;\n"
         "        if (reuse_language_encoder && params.abort_callback &&\n"
         "            params.abort_callback(params.abort_callback_user_data)) {\n"
         "            return -6;\n"
         "        }\n"
         "        // encode audio features starting at offset seek\n"
         "        if (!reuse_language_encoder && !whisper_encode_internal(*ctx, *state, seek, params.n_threads, params.abort_callback, params.abort_callback_user_data)) {\n"),
    ]
    for before, after in replacements:
        if text.count(before) != 1:
            raise ValueError("Whisper patch anchor changed or is ambiguous")
        text = text.replace(before, after, 1)
    return text


if __name__ == "__main__":
    pathlib.Path(sys.argv[2]).write_text(prepare(pathlib.Path(sys.argv[1]).read_bytes()))
