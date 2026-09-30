import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/notifications/notification_navigation.dart';
import 'package:internal_audit_app/models/audit_model.dart';
import 'package:internal_audit_app/models/employee_option.dart';

void main() {
  group('notification payload owner', () {
    test('a payload without a recipient decodes exactly as before', () {
      final p = encodeNotificationPayload(type: 'audit_created', referenceId: 'a1');
      expect(p, 'audit_created|a1');
      final d = decodeNotificationPayload(p)!;
      expect(d.type, 'audit_created');
      expect(d.referenceId, 'a1');
      expect(notificationPayloadRecipient(p), isNull);
    });

    test('the recipient rides along without leaking into the reference id', () {
      final p = encodeNotificationPayload(
        type: 'audit_reassigned',
        referenceId: 'a1',
        recipientId: 'u9',
      );
      final d = decodeNotificationPayload(p)!;
      expect(d.type, 'audit_reassigned');
      expect(d.referenceId, 'a1');
      expect(notificationPayloadRecipient(p), 'u9');
    });

    test('an empty reference id stays null with a recipient present', () {
      final p = encodeNotificationPayload(type: 'morning_summary', referenceId: null, recipientId: 'u9');
      expect(decodeNotificationPayload(p)!.referenceId, isNull);
      expect(notificationPayloadRecipient(p), 'u9');
    });
  });

  group('leader rows', () {
    test('AuditModel reads the reassign verdict, auditors and places', () {
      final a = AuditModel.fromJson({
        '_id': 'a1',
        'title': 'Fire drill',
        'status': 'Not Started',
        'canReassign': true,
        'isCFT': false,
        'auditType': 'Safety',
        'auditorIds': [
          {'_id': 'e1', 'employeeName': 'Asha'},
          {'_id': 'e2', 'employeeName': 'Ravi', 'isActive': false},
        ],
        'locationIds': [
          {'_id': 'l1', 'name': 'Zone A'},
        ],
        'departmentIds': ['d1'],
        'scoreResult': {'scoredCount': 3},
      });
      expect(a.canReassign, isTrue);
      expect(a.auditors.map((x) => x.id), ['e1', 'e2']);
      expect(a.auditors[1].inactive, isTrue);
      expect(a.locationIdList, ['l1']);
      expect(a.departmentIdList, ['d1']);
      expect(a.scoredCount, 3);
    });

    test('a row from any other endpoint is never reassignable', () {
      final a = AuditModel.fromJson({'_id': 'a2', 'title': 'x', 'status': 'Not Started'});
      expect(a.canReassign, isFalse);
      expect(a.auditors, isEmpty);
      expect(a.reassignBlockedReason, isNull);
    });

    test('blocked rows carry the server reason', () {
      final a = AuditModel.fromJson({
        '_id': 'a3',
        'title': 'x',
        'status': 'In Progress',
        'canReassign': false,
        'reassignBlockedReason': 'This audit is past its due date',
      });
      expect(a.canReassign, isFalse);
      expect(a.reassignBlockedReason, 'This audit is past its due date');
    });

    test('EmployeeOption keeps the audit types the person is qualified for', () {
      final e = EmployeeOption.fromJson({
        '_id': 'e1',
        'employeeName': 'Asha',
        'auditTypeIds': ['t1', {'_id': 't2'}],
      });
      expect(e.auditTypeIds, ['t1', 't2']);
    });
  });
}
