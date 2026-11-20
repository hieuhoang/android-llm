# LLM Text

A Flutter app that runs local models using llamadart and llama.cpp. Select
Qwen3-0.6B Q8_0 for text and reasoning, or Qwen2.5-Omni-3B Q2_K, Q4_K_M or
Q8_0 for text, images and audio input. Omni's speech output is not supported by this runtime.
Omni is subject to the [Qwen Research License](https://huggingface.co/Qwen/Qwen2.5-Omni-3B/blob/main/LICENSE),
which permits non-commercial research/evaluation only unless separately licensed.
Enter a prompt and tap **Generate**. Previous prompts and responses are included
in later requests while they fit in the context window; the oldest turns are
removed as needed. Conversation history is kept in memory and is lost when the
app restarts. The conversation display retains older turns even when they no
longer fit in the model context. The **Enable reasoning** checkbox controls
thinking for each new Qwen3 request; it is enabled by default. Omni does not
support this reasoning mode. Generated reasoning is displayed,
but excluded from later requests, following Qwen's recommendation. A stopped
response may be retained as a partial turn; a turn with no final answer is not
included in later requests. Switching models retains conversation history; when
using the text-only model, earlier images and audio become labeled text
placeholders. Omni's **Load image/audio projector** checkbox is enabled by
default; turn it off for text-only requests to avoid downloading or loading the
projector. The change applies on the next generation and reloads the model.
Pending attachments must be removed or the projector re-enabled before sending.
Previous media becomes text placeholders when generating with the projector off;
re-enabling it does not restore that media to the model context.
**Clear conversation** clears both the display and
model context without unloading the model. The prompt field is cleared after
each attempt.

The Android build time appears at the top of the app in local time. It identifies the
compiled APK, not subsequent Flutter hot reloads.

On Android 10 or later, the app downloads models from Hugging Face to
the public Downloads folder using Android's Download Manager. It verifies each
download's SHA-256 checksum once, then reuses that result unless the download,
expected checksum, or file metadata changes. Files are read directly; the app
does not keep a private copy. Qwen3 is 639 MB; Omni's model and optional shared projector total about 2.92 GB
(Q2), 3.64 GB (Q4), or 5.15 GB (Q8), and can exceed the tablet's available
memory. Lower quantization saves memory but can reduce quality; Q4 and Q8 need
substantially more memory than Q2. Downloads are retained when switching models,
and the projector is reused. The system can
continue downloading while the app is closed. After
download, prompts and generation stay on the device. The screen stays on while
loading or generating; keeping the app in the foreground reduces the chance of
Android stopping it for memory pressure. Use **Stop** to interrupt loading or
generation. The models run on CPU by default. **Use GPU offloading** requests
Vulkan GPU inference on Android; the model reloads when this choice changes.
GPU support, memory use, and speed depend on the device; if loading fails,
disable GPU offloading to use the CPU. Conversation history is retained when
switching. The context is 2048 tokens for Qwen3 and 4096 tokens for Omni, with
up to 512 output tokens, and, when enabled, a
256-token thinking budget. The larger Omni context uses more memory. Longer
answers may be cut off; thinking mode can be slower.

Omni accepts selected JPG, PNG, GIF or BMP images, WAV, MP3 or FLAC audio files,
and microphone recordings. Selected media and recordings are copied to the
app's temporary storage for the current conversation and deleted when the app
closes normally. Longer audio and images consume context and memory.

## Run

```sh
flutter pub get
flutter run
```

Android and iOS are scaffolded; public model storage is currently implemented
only for Android. iOS requires macOS and iOS 16.4 or newer.

## Test

```sh
flutter test
```
