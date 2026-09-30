/// API base URL — points at the dev backend by default. Every real build
/// (debug or release, on a device or in the store) still gets exactly this
/// same server with zero extra flags, so nothing changes for the normal
/// workflow. The one override below exists ONLY for pointing a local
/// `flutter run` at a developer's own machine while testing a
/// not-yet-deployed server change (e.g. App Update) — pass
/// `--dart-define=API_BASE_URL=http://localhost:5001/api/v1` (iOS
/// Simulator reaches the host's `localhost` directly; an Android emulator
/// needs `http://10.0.2.2:5001/api/v1` instead, since `localhost` there
/// means the emulator itself).
class ApiConstants {
  ApiConstants._();

//   static const String prodUrl = 'https://audit.hqepl.com/api/v1';
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://devaudit.hqepl.com/api/v1',
  );

  /// Socket.io connects to the server root, not the /api/v1 REST prefix.
  static String get socketUrl {
    final uri = Uri.parse(baseUrl);
    return '${uri.scheme}://${uri.host}:${uri.port}';
  }

  // Auth
  static const login = '/auth/login';
  static const me = '/auth/me';
  static const mePreferences = '/auth/me/preferences';
  static const mePassword = '/auth/me/password';
  static const logout = '/auth/logout';
  static const sendOtp = '/auth/send-otp';
  static const verifyOtp = '/auth/verify-otp';
  static const resetPassword = '/auth/reset-password';

  // Audits / NC
  static const myAudits = '/audits/mine';
  // Every audit scheduled at one of MY OWN locations, whether or not I'm
  // personally the assigned auditor/auditee — powers the Auditee Calendar's
  // blue "someone's coming to audit your location" markers.
  static const auditsAtMyLocation = '/audits/at-my-location';
  // Places I lead (Zone / Sub Zone / Area leader, a department's HOD) and the
  // audits at them, whoever they are assigned to — the Final Report's
  // "My locations" view (audit.controller.js#getLedPlacesSummary /
  // getAuditsAtPlacesILead).
  static const ledPlaces = '/audits/led-places';
  static const auditsAtPlacesILead = '/audits/at-places-i-lead';
  // A leader (or the planner / a scheduler) hands one auditor's place on an
  // audit to someone else (audit.controller.js#reassignAuditor).
  static String reassignAuditor(String id) => '/audits/$id/reassign-auditor';
  // The Final Report (phone: the Reports tab), open to every logged-in user —
  // reached by who you ARE, not by a menu grant (audit.controller.js#
  // listReportAudits / getReportAuditStats). The list is paged over GROUPS (a
  // bundle or a series is one); the stats carry the six tiles, their id lists
  // and the per-place `byLocation` breakdown.
  static const auditsReport = '/audits/report';
  static const auditsReportStats = '/audits/report/stats';
  static const auditorStats = '/audits/stats/auditor';
  static const ncs = '/ncs';
  static String auditById(String id) => '/audits/$id';
  static String scoreParameter(String auditId, String nodeId) =>
      '/audits/$auditId/parameters/$nodeId/score';
  static String uploadEvidence(String auditId, String nodeId) =>
      '/audits/$auditId/parameters/$nodeId/evidence';
  // Polling fallback for a queued evidence-upload job — see
  // AuditsProvider#_waitForEvidenceJob.
  static String evidenceUploadStatus(String jobId) =>
      '/audits/uploads/status/$jobId';
  static String completeAudit(String id) => '/audits/$id/complete';
  // Every zone of a multi-document Schedule/Frequency batch, side by side —
  // unlike GET /audits/:id (auditById above), this is deliberately
  // unscoped to the caller's own assigned zone(s): anyone who's an auditor
  // on at least one zone (or planned the batch) gets every OTHER zone's
  // score/status too, same as the web app's AuditFullReport.jsx "All
  // Locations (Combined)" view (audit.controller.js#getBatchReport).
  static String auditBatchReport(String batchId) => '/audits/batch/$batchId/report';
  // Mobile's mandatory "pick one representative auditee" step, asked once
  // before scoring begins — see audit.controller.js#setAuditRepresentative.
  static String auditRepresentative(String id) => '/audits/$id/representative';
  static String mobileSubmitAudit(String id) => '/audits/$id/mobile-submit';
  // Instant Audit builder — same PATCH the web app's InstantAudit.jsx uses
  // for both "change location scope" and "add/remove a checkpoint" (it
  // replaces whichever whole field(s) are present in the body; see
  // audit.controller.js#applyAuditFields). Only usable while status stays
  // "Draft", which an Instant Audit always does.
  static String saveAuditDraft(String id) => '/audits/$id/save-draft';

  // For the Instant Audit builder's location-scope picker.
  static const locations = '/locations';

  // ── Filter option lists (Dashboard / Audits / Calendar filter sheet) ──
  // Which locations THIS user may filter by — their own Employee
  // Management record's locations, not the whole org (SuperAdmin/full
  // access still gets everything). Deliberately not `locations` above,
  // which is the paginated admin/CRUD list the Instant Audit scope picker
  // needs; this is the same endpoint the web app's LocationFilterSelect
  // uses (location.controller.js#getMyLocationScope).
  static const myLocationScope = '/locations/my-scope';
  // Every audit type, for the Audit Type filter. GET /audit-types is
  // deliberately ungated server-side (routes/auditType.routes.js) because
  // every audit-type picker in the app needs to read it regardless of who
  // is asking. activeOnly drops retired types from the picker.
  static const auditTypes = '/audit-types?activeOnly=true';
  // Self + everyone reporting into this user, transitively — the candidate
  // list for the employee filter, same endpoint backing the web app's
  // TeamFilterPanel. Each row carries its own locationIds, which is what
  // lets the filter narrow the people list down to the locations that are
  // currently selected without a second request.
  static const myHierarchyScope = '/employees/my-hierarchy-scope';

  // Everyone actually assigned to given Location(s) — the "who is this NC
  // against" and "select representative auditee" pickers' real candidate
  // list (see AuditsProvider.fetchLocationEmployees), deliberately not
  // scoped by manager-hierarchy or audit type — an auditee is whoever is
  // actually at the zone being audited.
  static String employeesByLocation(
    List<String> locationIds, {
    List<String> departmentIds = const [],
  }) {
    final params = <String>[
      if (locationIds.isNotEmpty) 'locationIds=${locationIds.join(",")}',
      if (departmentIds.isNotEmpty) 'departmentIds=${departmentIds.join(",")}',
    ];
    return '/employees/by-location?${params.join("&")}';
  }

  static const ncsRaised = '/ncs/raised'; // auditor: NCs I raised
  static const ncsMine = '/ncs/mine'; // auditee: NCs raised against me
  static const ncsAtsSummary =
      '/ncs/ats-summary'; // auditee: dashboard tallies (nc.controller.js#getAtsSummary)
  // NC Monitoring's six tiles + the ids behind each (nc.controller.js#
  // getRaisedNCStats) — same filters as /ncs/raised.
  static const ncsRaisedStats = '/ncs/raised/stats';
  // The Final Report's NCs tab: every NC the caller may see (by who they ARE,
  // not by a menu), its six tiles and per-place tallies, and the Repeated NCs
  // tab's groups (same wording at the same place) with the NCs behind one.
  static const ncsReport = '/ncs/report';
  static const ncsReportStats = '/ncs/report/stats';
  static const ncsRepeats = '/ncs/repeats';
  static const ncsRepeatRows = '/ncs/repeats/rows';
  // One NC's full detail by id — used to resolve a notification's
  // referenceId into a full NcModel before navigating to it (see
  // notifications_screen.dart), since a nc_* notification only carries
  // the id, not the whole NC.
  static String ncDetail(String id) => '/ncs/$id';
  static String ncRespond(String id) => '/ncs/$id/respond';
  static String ncMoveToVerification(String id) =>
      '/ncs/$id/move-to-verification';
  static String ncVerify(String id) => '/ncs/$id/verify';

  // Notifications
  static const notifications = '/notifications';
  static const notificationsUnreadCount = '/notifications/unread-count';
  static const notificationsReadAll = '/notifications/read-all';
  static String notificationRead(String id) => '/notifications/$id/read';

  // FCM device-token registration (fcm_service.dart) — server/routes/
  // deviceToken.routes.js, the phone counterpart of the web app's own
  // POST/DELETE /push/subscribe.
  static const deviceTokenRegister = '/device-tokens/register';
  // Sends a real test push to the caller's own phones and reports, per
  // device, whether Firebase accepted it (Settings > Send a test notification).
  static const deviceTokenTest = '/device-tokens/test';

  // Maintenance mode — public, no auth required (see server/routes/
  // maintenance.routes.js). MaintenanceProvider polls this.
  static const maintenanceStatus = '/maintenance/status';

  // Announcement mode — public, no auth required (see server/routes/
  // announcement.routes.js). AnnouncementProvider polls this.
  static const announcementStatus = '/announcement/status';

  // Force-update gate — public, no auth required (see server/routes/
  // appUpdate.routes.js). AppUpdateProvider reads this before login even
  // resolves, same reasoning as maintenanceStatus above.
  static const appUpdateStatus = '/app-update/status';

  // Global company config — the report PDF's header line, matching the
  // web Full Report's own `useCompany()` (companies.api.js#getCompanyDetails).
  // Public, no auth required (see server/routes/company.routes.js).
  static const companyDetails = '/companies/getCompanyDetails';

  // Tickets
  static const tickets = '/tickets';
  static const ticketsUnreadCount = '/tickets/unread-count';
  static String ticketById(String id) => '/tickets/$id';
  static String ticketReply(String id) => '/tickets/$id/reply';
  static String ticketRead(String id) => '/tickets/$id/read';
  // The raiser's answer to a "please confirm" request — POST { action:
  // 'Accept' | 'Reject', reason? } (ticket.controller.js#verifyTicket).
  // Accept closes the ticket, Reject sends it back to In Progress.
  static String ticketVerify(String id) => '/tickets/$id/verify';
}
