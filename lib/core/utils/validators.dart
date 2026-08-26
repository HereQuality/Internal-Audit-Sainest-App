class Validators {
  Validators._();

  static final _passwordRegex = RegExp(r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).{8,}$');
  static final _mobileRegex = RegExp(r'^\d{10}$');
  static final _emailRegex = RegExp(r'^[\w.+-]+@[\w-]+\.[\w.-]+$');

  static String? required(String? value, {String field = 'This field'}) {
    if (value == null || value.trim().isEmpty) return '$field is required';
    return null;
  }

  static String? email(String? value) {
    if (value == null || value.trim().isEmpty) return 'Email is required';
    if (!_emailRegex.hasMatch(value.trim())) return 'Enter a valid email';
    return null;
  }

  static String? mobile(String? value) {
    if (value == null || value.trim().isEmpty) return 'Mobile number is required';
    if (!_mobileRegex.hasMatch(value.trim())) return 'Enter a valid 10-digit mobile number';
    return null;
  }

  // Same format check as `mobile`/`email`, without the required check —
  // for the Edit Profile screen, where mobile number and office email are
  // optional (server already accepts either as empty/unset, see
  // profile.controller.js#updateOwnProfile), but should still be rejected
  // if someone types something malformed rather than silently saved.
  static String? mobileOptional(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    if (!_mobileRegex.hasMatch(value.trim())) return 'Enter a valid 10-digit mobile number';
    return null;
  }

  static String? emailOptional(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    if (!_emailRegex.hasMatch(value.trim())) return 'Enter a valid email';
    return null;
  }

  static String? password(String? value) {
    if (value == null || value.isEmpty) return 'Password is required';
    if (!_passwordRegex.hasMatch(value)) {
      return 'Min 8 characters with an uppercase, lowercase & number';
    }
    return null;
  }

  static String? confirmPassword(String? value, String original) {
    if (value == null || value.isEmpty) return 'Please confirm the password';
    if (value != original) return 'Passwords do not match';
    return null;
  }
}
