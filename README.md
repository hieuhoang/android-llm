# LLM Text

A Flutter app that runs Qwen3-0.6B Q8_0 locally using llamadart and llama.cpp.
Enter a prompt and tap **Generate**. Each prompt is independent; previous
prompts are not included in subsequent requests.

On Android 10 or later, the app downloads the 639 MB model from Hugging Face to
the public Downloads folder using Android's Download Manager. It verifies the
SHA-256 checksum and reads the public file directly; it does not keep a private
copy. The system can continue downloading while the app is closed. After
download, prompts and generation stay on the device. Use **Stop** to interrupt
loading or generation. The model runs on CPU with a 2048-token context and up
to 256 output tokens.

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
