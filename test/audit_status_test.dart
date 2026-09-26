import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:internal_audit_app/core/theme/app_colors.dart';
import 'package:internal_audit_app/core/theme/app_theme.dart';
import 'package:internal_audit_app/core/utils/audit_status.dart';
import 'package:internal_audit_app/models/audit_model.dart';

/// The unified audit-status vocabulary on the phone: which colour each label
/// gets (and that it stays readable in both themes), which audits each filter
/// chip matches, and the one status a batch's parent row shows. The server
/// decides the statuses; these cover only what the app does with them.
void main() {
  AuditModel audit({
    String status = 'Not Started',
    String? displayStatus,
    String? timeliness,
    String? batchDisplayStatus,
    String? batchTimeliness,
    String id = 'a',
  }) => AuditModel(
    id: id,
    title: 'Audit $id',
    scope: '',
    status: status,
    displayStatus: displayStatus,
    timeliness: timeliness,
    batchDisplayStatus: batchDisplayStatus,
    batchTimeliness: batchTimeliness,
  );

  group('AppColors.forAuditStatus', () {
    test('every pipeline label has its own colour', () {
      final colors = AuditStatus.pipeline.map(AppColors.forAuditStatus).toSet();
      expect(colors, hasLength(AuditStatus.pipeline.length));
    });

    test('follows the status contract palette', () {
      // Not Started slate · In Progress blue · Overdue red · Delayed
      // Completed orange · On-Time Completed green · NC Response Pending
      // amber · NC Verification Pending violet · Total Closed teal — checked
      // by hue family, so a shade tweak passes and swapping two statuses'
      // families does not.
      HSVColor hsv(String s) => HSVColor.fromColor(AppColors.forAuditStatus(s));
      expect(hsv('Not Started').saturation, lessThan(0.35)); // grey-blue slate
      expect(hsv('In Progress').hue, inInclusiveRange(205, 235)); // blue
      final red = hsv('Overdue').hue;
      expect(red < 12 || red > 350, isTrue, reason: 'red hue $red');
      expect(hsv('Delayed Completed').hue, inInclusiveRange(15, 32)); // orange
      expect(hsv('On-Time Completed').hue, inInclusiveRange(120, 160)); // green
      expect(hsv('NC Response Pending').hue, inInclusiveRange(35, 50)); // amber
      expect(hsv('NC Verification Pending').hue, inInclusiveRange(250, 275)); // violet
      expect(hsv('Total Closed').hue, inInclusiveRange(165, 185)); // teal
    });

    test('Draft and Skipped keep their old colours, legacy Completed stays green', () {
      expect(AppColors.forAuditStatus('Draft'), AppColors.slate);
      expect(AppColors.forAuditStatus('Skipped'), AppColors.red);
      expect(AppColors.forAuditStatus('Completed'), AppColors.green);
    });

    test('an unknown label is neutral slate, not another status\'s colour', () {
      expect(AppColors.forAuditStatus('On Hold'), AppColors.slate);
      expect(AppColors.forAuditStatus(''), AppColors.slate);
    });

    // WCAG contrast of the badge text over its own 12% tint on the theme's
    // card surface — the same recipe StatusBadge paints (label in
    // AppColors.readable(...) over color.withValues(alpha: .12)). Held to
    // AA's 4.5:1 for the eight lifecycle statuses on BOTH themes; Draft and
    // Skipped are the pre-existing slate/red tokens and are not re-tuned.
    double contrast(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      final hi = la > lb ? la : lb;
      final lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    Color over(Color tint, Color bg) => Color.alphaBlend(tint.withValues(alpha: 0.12), bg);

    test('badge text is AA-readable on the light theme', () {
      final card = AppTheme.light().cardTheme.color!;
      final scaffold = AppTheme.light().scaffoldBackgroundColor;
      for (final label in AuditStatus.pipeline) {
        final c = AppColors.forAuditStatus(label);
        expect(contrast(c, over(c, card)), greaterThanOrEqualTo(4.5), reason: '$label on card');
        expect(contrast(c, over(c, scaffold)), greaterThanOrEqualTo(4.5), reason: '$label on scaffold');
      }
    });

    test('badge text is AA-readable on the dark theme (after AppColors.readable\'s lightening)', () {
      final card = AppTheme.dark().cardTheme.color!;
      final scaffold = AppTheme.dark().scaffoldBackgroundColor;
      for (final label in AuditStatus.pipeline) {
        final c = AppColors.forAuditStatus(label);
        // Same lerp AppColors.readable applies for Brightness.dark.
        final text = Color.lerp(c, Colors.white, 0.3)!;
        expect(contrast(text, over(c, card)), greaterThanOrEqualTo(4.5), reason: '$label on card');
        expect(contrast(text, over(c, scaffold)), greaterThanOrEqualTo(4.5), reason: '$label on scaffold');
      }
    });
  });

  group('auditMatchesStatusFilter', () {
    test('All matches everything, Draft included', () {
      expect(auditMatchesStatusFilter(audit(status: 'Draft'), 'All'), isTrue);
      expect(auditMatchesStatusFilter(audit(displayStatus: 'Overdue'), 'All'), isTrue);
    });

    test('the lifecycle chips match the label the badge shows (displayStatus)', () {
      final overdue = audit(status: 'In Progress', displayStatus: 'Overdue');
      // The raw status says In Progress for an overdue audit — the chip
      // follows what the badge says, so this is Overdue and NOT In Progress.
      expect(auditMatchesStatusFilter(overdue, 'Overdue'), isTrue);
      expect(auditMatchesStatusFilter(overdue, 'In Progress'), isFalse);

      final closed = audit(status: 'Completed', displayStatus: 'Total Closed', timeliness: 'On-Time Completed');
      expect(auditMatchesStatusFilter(closed, 'Total Closed'), isTrue);
      expect(auditMatchesStatusFilter(closed, 'NC Response Pending'), isFalse);
      expect(auditMatchesStatusFilter(closed, 'NC Verification Pending'), isFalse);
      expect(auditMatchesStatusFilter(closed, 'Not Started'), isFalse);
    });

    test('Delayed / On-Time Completed match a stored-Completed audit by timeliness, at ANY NC stage', () {
      final lateAndWaiting = audit(
        status: 'Completed',
        displayStatus: 'NC Response Pending',
        timeliness: 'Delayed Completed',
      );
      // One audit, two chips — the status contract's "counted in a
      // timeliness tile and an NC tile at once".
      expect(auditMatchesStatusFilter(lateAndWaiting, 'Delayed Completed'), isTrue);
      expect(auditMatchesStatusFilter(lateAndWaiting, 'NC Response Pending'), isTrue);
      expect(auditMatchesStatusFilter(lateAndWaiting, 'On-Time Completed'), isFalse);
      expect(auditMatchesStatusFilter(lateAndWaiting, 'Total Closed'), isFalse);

      final onTimeVerifying = audit(
        status: 'Completed',
        displayStatus: 'NC Verification Pending',
        timeliness: 'On-Time Completed',
      );
      expect(auditMatchesStatusFilter(onTimeVerifying, 'On-Time Completed'), isTrue);
      expect(auditMatchesStatusFilter(onTimeVerifying, 'Delayed Completed'), isFalse);
      expect(auditMatchesStatusFilter(onTimeVerifying, 'NC Verification Pending'), isTrue);
    });

    test('the timeliness chips follow the server\'s timeliness alone — no client gate on top', () {
      // The server sends a timeliness for exactly the audits its auditor has
      // completed; that is what makes On-Time + Delayed equal the three NC
      // stages. A second client rule (say "and status is Completed") could
      // only make the list disagree with the dashboard tile it came from.
      final late = audit(status: 'Completed', displayStatus: 'Total Closed', timeliness: 'Delayed Completed');
      expect(auditMatchesStatusFilter(late, 'Delayed Completed'), isTrue);
      expect(auditMatchesStatusFilter(late, 'On-Time Completed'), isFalse);
      // No timeliness from the server -> not under either chip, whatever the
      // label says.
      expect(auditMatchesStatusFilter(audit(displayStatus: 'Overdue'), 'Delayed Completed'), isFalse);
      expect(auditMatchesStatusFilter(audit(displayStatus: 'Overdue'), 'On-Time Completed'), isFalse);
      expect(auditMatchesStatusFilter(audit(status: 'Completed', displayStatus: 'Total Closed'), 'On-Time Completed'), isFalse);
    });

    test('an audit with no timeliness (older server) matches neither timeliness chip', () {
      final done = audit(status: 'Completed');
      expect(auditMatchesStatusFilter(done, 'Delayed Completed'), isFalse);
      expect(auditMatchesStatusFilter(done, 'On-Time Completed'), isFalse);
    });

    test('legacy Completed gates on the RAW status — the Final Report default list', () {
      expect(auditMatchesStatusFilter(audit(status: 'Completed', displayStatus: 'Total Closed'), 'Completed'), isTrue);
      expect(auditMatchesStatusFilter(audit(status: 'Completed', displayStatus: 'NC Response Pending'), 'Completed'), isTrue);
      expect(auditMatchesStatusFilter(audit(status: 'Completed'), 'Completed'), isTrue); // older server
      expect(auditMatchesStatusFilter(audit(status: 'In Progress', displayStatus: 'Overdue'), 'Completed'), isFalse);
      // A displayStatus can never smuggle a not-completed audit in.
      expect(auditMatchesStatusFilter(audit(status: 'Draft', displayStatus: 'Total Closed'), 'Completed'), isFalse);
    });

    test('an older server keeps Not Started / In Progress working off the raw status', () {
      expect(auditMatchesStatusFilter(audit(status: 'Not Started'), 'Not Started'), isTrue);
      expect(auditMatchesStatusFilter(audit(status: 'In Progress'), 'In Progress'), isTrue);
      expect(auditMatchesStatusFilter(audit(status: 'In Progress'), 'Not Started'), isFalse);
      // …and a label an old server cannot express simply matches nothing.
      expect(auditMatchesStatusFilter(audit(status: 'In Progress'), 'Overdue'), isFalse);
      expect(auditMatchesStatusFilter(audit(status: 'Completed'), 'Total Closed'), isFalse);
    });

    test('the chip row is All plus the eight statuses, in the owner\'s order', () {
      expect(auditStatusFilterOptions, [
        'All',
        'Not Started',
        'In Progress',
        'Overdue',
        'Delayed Completed',
        'On-Time Completed',
        'NC Response Pending',
        'NC Verification Pending',
        'Total Closed',
      ]);
    });

    test('every chip except All is matched by at least one audit shape', () {
      // Guards a chip that can never light up (a typo'd label).
      final samples = [
        audit(displayStatus: 'Not Started'),
        audit(status: 'In Progress', displayStatus: 'In Progress'),
        audit(status: 'In Progress', displayStatus: 'Overdue'),
        audit(status: 'Completed', displayStatus: 'Total Closed', timeliness: 'Delayed Completed'),
        audit(status: 'Completed', displayStatus: 'NC Response Pending', timeliness: 'On-Time Completed'),
        audit(status: 'Completed', displayStatus: 'NC Verification Pending', timeliness: 'On-Time Completed'),
        audit(status: 'Completed', displayStatus: 'Total Closed', timeliness: 'On-Time Completed'),
      ];
      for (final chip in auditStatusFilterOptions.skip(1)) {
        expect(samples.any((a) => auditMatchesStatusFilter(a, chip)), isTrue, reason: chip);
      }
    });

    test('empty-state title reads for every chip', () {
      expect(auditStatusEmptyTitle('Overdue'), 'No audits are Overdue');
      expect(auditStatusEmptyTitle('Not Started'), 'No audits are Not Started');
      expect(auditStatusEmptyTitle('NC Response Pending'), 'No audits are NC Response Pending');
    });
  });

  group('completed audits split the same way by timeliness and by NC stage', () {
    // What the server guarantees for a list of rows: a completed audit has a
    // timeliness AND exactly one NC stage; nothing else has either. So filtering
    // a list by the two timeliness chips and by the three NC-stage chips picks
    // the same audits — the row-level twin of the dashboard tiles' identity.
    test('On-Time + Delayed matches exactly the rows the three NC stages match', () {
      final rows = [
        audit(id: '1', status: 'Completed', displayStatus: 'NC Response Pending', timeliness: 'Delayed Completed'),
        audit(id: '2', status: 'Completed', displayStatus: 'NC Verification Pending', timeliness: 'On-Time Completed'),
        audit(id: '3', status: 'Completed', displayStatus: 'Total Closed', timeliness: 'On-Time Completed'),
        audit(id: '4', status: 'Completed', displayStatus: 'Total Closed', timeliness: 'Delayed Completed'),
        audit(id: '5', status: 'In Progress', displayStatus: 'Overdue'),
        audit(id: '6', status: 'Not Started', displayStatus: 'Not Started'),
        audit(id: '7', status: 'In Progress', displayStatus: 'In Progress'),
      ];
      Set<String> ids(List<String> chips) => {
        for (final r in rows)
          if (chips.any((c) => auditMatchesStatusFilter(r, c))) r.id,
      };
      final byTimeliness = ids([AuditStatus.onTimeCompleted, AuditStatus.delayedCompleted]);
      final byNcStage = ids([AuditStatus.ncResponsePending, AuditStatus.ncVerificationPending, AuditStatus.totalClosed]);
      expect(byTimeliness, {'1', '2', '3', '4'});
      expect(byNcStage, byTimeliness);
    });

    test('a row is never invented into a timeliness by the client', () {
      // NC stage without a timeliness (not something the server sends) stays
      // outside both timeliness chips: the client does not derive one.
      final odd = audit(status: 'Completed', displayStatus: 'Total Closed');
      expect(auditMatchesStatusFilter(odd, AuditStatus.onTimeCompleted), isFalse);
      expect(auditMatchesStatusFilter(odd, AuditStatus.delayedCompleted), isFalse);
    });
  });

  group('auditGroupStatus (a batch parent row)', () {
    test('is the server\'s batch aggregate, not the members\' own labels', () {
      final members = [
        audit(id: '1', status: 'Completed', displayStatus: 'Total Closed', batchDisplayStatus: 'In Progress'),
        audit(id: '2', status: 'Completed', displayStatus: 'Total Closed', batchDisplayStatus: 'In Progress'),
      ];
      // Both visible zones are Total Closed, but the batch has a third zone
      // (another auditor's) still open — the parent must not claim Closed.
      expect(auditGroupStatus(members), 'In Progress');
    });

    test('is never "Mixed" once the server sends the aggregate', () {
      final members = [
        audit(id: '1', displayStatus: 'Overdue', batchDisplayStatus: 'Overdue'),
        audit(id: '2', displayStatus: 'Not Started', batchDisplayStatus: 'Overdue'),
      ];
      expect(auditGroupStatus(members), 'Overdue');
    });

    test('takes the first zone that carries it', () {
      final members = [
        audit(id: '1'),
        audit(id: '2', batchDisplayStatus: 'NC Verification Pending'),
      ];
      expect(auditGroupStatus(members), 'NC Verification Pending');
    });

    test('older server: the zones\' shared label when they agree, else Mixed', () {
      expect(auditGroupStatus([audit(id: '1', status: 'Completed'), audit(id: '2', status: 'Completed')]), 'Completed');
      expect(auditGroupStatus([audit(id: '1', status: 'Completed'), audit(id: '2', status: 'In Progress')]), 'Mixed');
    });

    test('timeliness is the batch\'s, only once the server sends it', () {
      final done = [
        audit(id: '1', batchDisplayStatus: 'Total Closed', batchTimeliness: 'Delayed Completed'),
        audit(id: '2', batchDisplayStatus: 'Total Closed', batchTimeliness: 'Delayed Completed'),
      ];
      expect(auditGroupTimeliness(done), 'Delayed Completed');
      expect(auditGroupTimeliness([audit(id: '1', batchDisplayStatus: 'In Progress')]), isNull);
    });
  });
}
