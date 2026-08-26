/// Which stage a checkpoint evidence-photo upload is in — surfaced by
/// AuditsProvider#scoreCheckpoint's onProgress callback so checkpoint_card.dart
/// can show "Uploading X%…" / "Processing…" instead of one opaque "Saving…"
/// spinner for the whole thing. A plain enum (not defined in either the
/// provider or the widget file) so checkpoint_card.dart can depend on it
/// without depending on AuditsProvider itself — it stays provider-agnostic.
enum UploadPhase { uploading, processing }
