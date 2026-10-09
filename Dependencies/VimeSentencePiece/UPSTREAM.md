SentencePiece v0.2.1, https://github.com/google/sentencepiece/tree/v0.2.1
Apache-2.0. Runtime sources only, internal protobuf-lite/absl bundled.
Archive SHA256: c1a59e9259c9653ad0ade653dadff074cd31f0a6ff2a11316f67bee4189a8f1b
config.h supplies build version; embedded normalization data disabled (normalization is in tokenizer.model).
Bridge.cc and include/VimeSentencePiece.h are Vime C wrappers.

Local changes (2026-10-09):
- Package.swift disables only Clang's shorten-64-to-32 warning within this bundled
  dependency. Upstream protobuf lengths and SentencePiece IDs use 32-bit APIs.
  This is a diagnostic exception, not a claim that every upstream cast is safe.
  Bridge.cc re-enables the warning for Vime's own wrapper and rejects input sizes
  beyond INT_MAX before calling those APIs. Other compiler warnings stay enabled.
- protobuf-lite/strutil.cc writes four-byte hex/octal escapes directly instead of
  using deprecated sprintf. This also avoids an intermediate terminator writing
  past the end when exactly four bytes remain; the final terminator is checked
  separately by the existing function.
