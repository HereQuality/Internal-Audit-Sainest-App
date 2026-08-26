import 'package:flutter_test/flutter_test.dart';

import 'package:internal_audit_app/core/utils/validators.dart';

void main() {
  group('Validators', () {
    test('password requires upper, lower, digit and min length', () {
      expect(Validators.password('short1A'), isNotNull);
      expect(Validators.password('nouppercase1'), isNotNull);
      expect(Validators.password('NOLOWERCASE1'), isNotNull);
      expect(Validators.password('NoDigitsHere'), isNotNull);
      expect(Validators.password('ValidPass1'), isNull);
    });

    test('mobile requires exactly 10 digits', () {
      expect(Validators.mobile('12345'), isNotNull);
      expect(Validators.mobile('98765432101'), isNotNull);
      expect(Validators.mobile('9876543210'), isNull);
    });

    test('confirmPassword matches original', () {
      expect(Validators.confirmPassword('abc', 'xyz'), isNotNull);
      expect(Validators.confirmPassword('abc', 'abc'), isNull);
    });
  });
}
