import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/constants/api_constants.dart';
import '../../core/network/dio_client.dart';
import '../../core/utils/snackbar.dart';
import '../../core/utils/validators.dart';
import '../../core/theme/app_colors.dart';

enum _Step { email, otp, newPassword, done }

/// Mirrors the web app's forgot-password flow: email -> OTP -> new password.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _dio = DioClient.instance.dio;

  _Step _step = _Step.email;
  bool _isBusy = false;

  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isBusy = true);
    try {
      await _dio.post(ApiConstants.sendOtp, data: {'email': _emailController.text.trim()});
      if (!mounted) return;
      showSuccessSnackBar(context, 'If that email exists, an OTP has been sent.');
      setState(() => _step = _Step.otp);
    } on DioException catch (e) {
      if (mounted) showErrorSnackBar(context, extractErrorMessage(e));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _verifyOtp() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isBusy = true);
    try {
      await _dio.post(ApiConstants.verifyOtp, data: {
        'email': _emailController.text.trim(),
        'otp': _otpController.text.trim(),
      });
      if (!mounted) return;
      setState(() => _step = _Step.newPassword);
    } on DioException catch (e) {
      if (mounted) showErrorSnackBar(context, extractErrorMessage(e, fallback: 'Invalid or expired OTP.'));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _resetPassword() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isBusy = true);
    try {
      await _dio.post(ApiConstants.resetPassword, data: {
        'email': _emailController.text.trim(),
        'otp': _otpController.text.trim(),
        'newPassword': _newPasswordController.text,
      });
      if (!mounted) return;
      setState(() => _step = _Step.done);
    } on DioException catch (e) {
      if (mounted) showErrorSnackBar(context, extractErrorMessage(e));
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset Password')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(key: _formKey, child: _buildStep()),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case _Step.email:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Enter your office email and we will send you a one-time code.',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Office Email', prefixIcon: Icon(Icons.email_outlined)),
              validator: Validators.email,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isBusy ? null : _sendOtp,
              child: _isBusy ? const _ButtonSpinner() : const Text('Send OTP'),
            ),
          ],
        );
      case _Step.otp:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Enter the 6-digit code sent to ${_emailController.text.trim()}',
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            TextFormField(
              controller: _otpController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              decoration: const InputDecoration(labelText: 'OTP', prefixIcon: Icon(Icons.pin_outlined)),
              validator: (v) => Validators.required(v, field: 'OTP'),
            ),
            ElevatedButton(
              onPressed: _isBusy ? null : _verifyOtp,
              child: _isBusy ? const _ButtonSpinner() : const Text('Verify OTP'),
            ),
          ],
        );
      case _Step.newPassword:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Choose a new password.', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            TextFormField(
              controller: _newPasswordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New Password', prefixIcon: Icon(Icons.lock_outline)),
              validator: Validators.password,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirmPasswordController,
              obscureText: true,
              decoration:
                  const InputDecoration(labelText: 'Confirm Password', prefixIcon: Icon(Icons.lock_outline)),
              validator: (v) => Validators.confirmPassword(v, _newPasswordController.text),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isBusy ? null : _resetPassword,
              child: _isBusy ? const _ButtonSpinner() : const Text('Reset Password'),
            ),
          ],
        );
      case _Step.done:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: AppColors.green, size: 56),
            const SizedBox(height: 16),
            Text('Password reset successfully', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('You can now sign in with your new password.', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back to Sign In'),
            ),
          ],
        );
    }
  }
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 20,
      width: 20,
      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
    );
  }
}
