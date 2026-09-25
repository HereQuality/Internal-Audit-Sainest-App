import 'package:flutter/material.dart';

import '../core/theme/app_colors.dart';

class StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const StatusBadge({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        // readable(): the raw token is only 2.5-3.6:1 on the tinted pill in dark mode.
        style: TextStyle(color: AppColors.readable(context, color), fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
