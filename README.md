# LLM Text

A Flutter app that runs Qwen3-0.6B Q8_0 locally using llamadart and llama.cpp.
Enter a prompt and tap **Generate**. Previous prompts and responses are included
in later requests while they fit in the context window; the oldest turns are
removed as needed. Conversation history is kept in memory and is lost when the
app restarts. The conversation display retains older turns even when they no
longer fit in the model context. The **Enable reasoning** checkbox controls
thinking for each new request; it is enabled by default. Generated reasoning is displayed,
but excluded from later requests, following Qwen's recommendation. A stopped
response may be retained as a partial turn; a turn with no final answer is not
included in later requests. **Clear conversation** clears both the display and
model context without unloading the model. The prompt field is cleared after
each attempt.

The Android build time appears at the top of the app in local time. It identifies the
compiled APK, not subsequent Flutter hot reloads.

On Android 10 or later, the app downloads the 639 MB model from Hugging Face to
the public Downloads folder using Android's Download Manager. It verifies the
SHA-256 checksum and reads the public file directly; it does not keep a private
copy. The system can continue downloading while the app is closed. After
download, prompts and generation stay on the device. Use **Stop** to interrupt
loading or generation. The model runs on CPU with a 2048-token context, up to
512 output tokens, and, when enabled, a 256-token thinking budget. Longer
answers may be cut off; thinking mode can be slower.

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
