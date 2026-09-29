/// Which stage a checkpoint evidence-photo upload is in — surfaced by
/// AuditsProvider#scoreCheckpoint's onProgress callback so checkpoint_card.dart
/// can show "Uploading X%…" / "Processing…" instead of one opaque "Saving…"
/// spinner for the whole thing. A plain enum (not defined in either the
/// provider or the widget file) so checkpoint_card.dart can depend on it
/// without depending on AuditsProvider itself — it stays provider-agnostic.
enum UploadPhase { uploading, processing }

/// Result of one evidence-photo upload attempt (AuditsProvider
/// #uploadCheckpointEvidence) — a batch is sent together in one request,
/// but the server confirms each file via its own background job, so it can
/// PARTIALLY succeed (e.g. 3 of 5 attach before the other 2 time out under
/// server load). `failedPaths` is exactly which of the files sent didn't
/// get confirmed, so a retry only resends those — never the ones that
/// already succeeded, which would otherwise be re-uploaded (and
/// duplicated) on every retry.
class UploadPhotosResult {
  final Set<String> failedPaths;
  final String? error;
  const UploadPhotosResult({this.failedPaths = const {}, this.error});
  bool get allSucceeded => failedPaths.isEmpty;
}
