import 'package:flutter/material.dart';

import '../utils/bold_marks.dart';

/// A parameter / checkpoint name with its `**bold**` stretches drawn bold (see utils/bold_marks.dart). A name with
/// no marks is a plain [Text], so nothing else about it changes.
class BoldText extends StatelessWidget {
  const BoldText(this.text, {super.key, this.style, this.maxLines, this.overflow});

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    if (!hasBold(text)) return Text(text, style: style, maxLines: maxLines, overflow: overflow);
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          for (final s in boldSegments(text))
            TextSpan(text: s.text, style: s.bold ? const TextStyle(fontWeight: FontWeight.w800) : null),
        ],
      ),
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}
