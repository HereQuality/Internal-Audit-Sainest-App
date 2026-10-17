/// Which stage a checkpoint evidence-photo upload is in — surfaced by
/// AuditsProvider#scoreCheckpoint's onProgress callback so checkpoint_card.dart
/// can show "Uploading X%…" / "Processing…" instead of one opaque "Saving…"
/// spinner for the whole thing. A plain enum (not defined in either the
/// provider or the widget file) so checkpoint_card.dart can depend on it
/// without depending on AuditsProvider itself — it stays provider-agnostic.
enum UploadPhase { uploading, processing }

/// Result of one evidence-photo upload attempt (AuditsProvider
/// #uploadCheckpointEvidence) — a batch is sent one photo per request,
/// and the server confirms each file via its own background job, so it can
/// PARTIALLY succeed (e.g. 3 of 5 attach before the other 2 time out under
/// server load). `failedPaths` is exactly which of the files sent didn't
/// get confirmed, so a retry only resends those — never the ones that
/// already succeeded, which would otherwise be re-uploaded (and
/// duplicated) on every retry.
///
/// `uploadedUrls` maps each CONFIRMED file's path to the hosted URL the
/// server attached it under. The card shows a confirmed photo from this
/// straight away instead of waiting for the audit to be fetched again — a
/// fetch that fails (a weak mobile connection) used to leave a photo that
/// was safely saved looking like it had vanished.
class UploadPhotosResult {
  final Set<String> failedPaths;
  final String? error;
  final Map<String, String> uploadedUrls;

  /// The part of `failedPaths` that sending again cannot fix — a file the server refuses (wrong type, too big), a job
  /// the server gave up on, a photo whose job is still running. The card does not retry these on its own.
  final Set<String> permanentPaths;
  const UploadPhotosResult({this.failedPaths = const {}, this.error, this.uploadedUrls = const {}, this.permanentPaths = const {}});
  bool get allSucceeded => failedPaths.isEmpty;
}
