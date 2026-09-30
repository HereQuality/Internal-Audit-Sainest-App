import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:internal_audit_app/core/constants/api_constants.dart';
import 'package:internal_audit_app/core/network/dio_client.dart';
import 'package:internal_audit_app/core/network/socket_service.dart';
import 'package:internal_audit_app/providers/audits_provider.dart';
import 'package:internal_audit_app/providers/filter_options_provider.dart';
import 'package:internal_audit_app/providers/nc_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_fakes.dart';

/// Ordering guarantees of the providers: a retried verify, an older answer
/// landing after a newer one, a load that outlives its account, and bursts of
/// live events.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAdapter adapter;
  late FakeSockets sockets;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    adapter = FakeAdapter();
    DioClient.instance.dio.httpClientAdapter = adapter;
    sockets = FakeSockets();
    SocketService.debugInstance = sockets.service;
  });

  Map<String, dynamic> audit(String title) => {'_id': 'a1', 'title': title};

  test('verify: a retry after a failed verify does not move to Verification again', () async {
    var verifyCalls = 0;
    adapter.handler = (o) async {
      if (o.path == ApiConstants.ncMoveToVerification('nc1')) return json(200, {'data': {}});
      if (o.path == ApiConstants.ncVerify('nc1')) {
        return ++verifyCalls == 1 ? json(500, {'message': 'boom'}) : json(200, {'data': {'_id': 'nc1', 'title': 'NC'}});
      }
      return json(404, {});
    };
    final nc = NcProvider();

    final first = await nc.verify(ncId: 'nc1', currentlyResponseSubmitted: true, action: 'Accept');
    expect(first, isNotNull);
    final second = await nc.verify(ncId: 'nc1', currentlyResponseSubmitted: true, action: 'Accept');
    expect(second, isNull);

    expect(adapter.where('POST', ApiConstants.ncMoveToVerification('nc1')), hasLength(1));
    expect(adapter.where('POST', ApiConstants.ncVerify('nc1')), hasLength(2));
  });

  test('fetchMyAudits: an older answer that lands last does not replace the newer one', () async {
    final gates = <Completer<void>>[];
    adapter.handler = (o) async {
      final index = gates.length;
      gates.add(Completer<void>());
      await gates[index].future;
      return json(200, {
        'data': [audit(index == 0 ? 'older request' : 'newer request')],
      });
    };
    final provider = AuditsProvider();

    final older = provider.fetchMyAudits();
    final newer = provider.fetchMyAudits();
    // Both requests must have reached the adapter before the gates are opened. A fixed number
    // of event-loop turns (settle) is not enough when the whole suite runs in parallel.
    await waitFor(() => gates.length == 2);
    gates[1].complete();
    await newer;
    gates[0].complete();
    await older;

    expect(provider.audits.single.title, 'newer request');
    expect(provider.isLoading, isFalse);
  });

  test('fetchAuditDetail: a quiet refetch never raises the loading flag and the newest answer wins', () async {
    final gates = <Completer<void>>[];
    adapter.handler = (o) async {
      final index = gates.length;
      gates.add(Completer<void>());
      await gates[index].future;
      return json(200, {'data': audit(index == 0 ? 'older' : 'newer')});
    };
    final provider = AuditsProvider();

    final older = provider.fetchAuditDetail('a1', quiet: true);
    final newer = provider.fetchAuditDetail('a1', quiet: true);
    await waitFor(() => gates.length == 2); // see fetchMyAudits above: not a fixed settle() under load
    expect(provider.isLoadingDetail, isFalse);
    gates[1].complete();
    await newer;
    gates[0].complete();
    await older;

    expect(provider.activeAudit!.title, 'newer');
  });

  test('a burst of audit notifications refetches the list once', () async {
    adapter.handler = (o) async => json(200, {'data': []});
    SocketService.instance.connect('jwt-A');
    final provider = AuditsProvider()..startListening();
    for (var i = 0; i < 3; i++) {
      sockets.sockets[0].receive('new_notification', {'type': 'audit_assigned'});
    }
    expect(adapter.where('GET', ApiConstants.myAudits), isEmpty);
    await waitFor(() => adapter.where('GET', ApiConstants.myAudits).isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(adapter.where('GET', ApiConstants.myAudits), hasLength(1));
    provider.stopListening();
  });

  test('FilterOptionsProvider: a load in flight at logout does not fill the next account, and does not stick', () async {
    final gate = Completer<void>();
    adapter.handler = (o) async {
      await gate.future;
      if (o.path == ApiConstants.myHierarchyScope) {
        return json(200, {
          'data': [
            {'_id': 'e1', 'employeeName': 'Old account person'},
          ],
        });
      }
      return json(200, {'data': []});
    };
    final options = FilterOptionsProvider();

    final loading = options.load();
    await settle();
    expect(options.isLoading, isTrue);
    options.resetForLogout();
    expect(options.isLoading, isFalse);
    gate.complete();
    await loading;

    expect(options.employees, isEmpty);
    // The next account's own load is not handed the dead one.
    adapter.handler = (o) async => json(200, {'data': []});
    await options.load();
    expect(options.isLoading, isFalse);
  });

  test('FilterOptionsProvider: an unreadable answer ends the load instead of leaving it spinning', () async {
    adapter.handler = (o) async => json(200, {'data': 'not a list of maps', 'departmentsByLocation': 5});
    final options = FilterOptionsProvider();
    await options.load();
    expect(options.isLoading, isFalse);
  });
}
