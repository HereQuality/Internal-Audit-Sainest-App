/// Bold inside a parameter / checkpoint NAME: a bold stretch is written `**like this**` inside the plain-string
/// name (the Audit Format editor on the web adds the marks with Ctrl/Cmd+B). The screens draw the marks as real
/// bold (see widgets/bold_text.dart and the PDF builder); anywhere that can't — a chart label, a dialog line —
/// uses [stripBold]. A lone `**` with no partner stays as typed.
/// Same rule as client/src/utils/boldMarks.js and server/utils/boldMarks.js — keep them in step.
library;

final RegExp _bold = RegExp(r'\*\*([\s\S]+?)\*\*');

/// One run of a name: its text and whether it is bold.
class BoldSegment {
  const BoldSegment(this.text, {required this.bold});
  final String text;
  final bool bold;
}

bool hasBold(String? text) => text != null && _bold.hasMatch(text);

/// "a **b** c" -> "a b c".
String stripBold(String? text) => (text ?? '').replaceAllMapped(_bold, (m) => m.group(1)!);

/// "a **b** c" -> [a ][b (bold)][ c].
List<BoldSegment> boldSegments(String? text) {
  final source = text ?? '';
  final out = <BoldSegment>[];
  var last = 0;
  for (final m in _bold.allMatches(source)) {
    if (m.start > last) out.add(BoldSegment(source.substring(last, m.start), bold: false));
    out.add(BoldSegment(m.group(1)!, bold: true));
    last = m.end;
  }
  if (last < source.length) out.add(BoldSegment(source.substring(last), bold: false));
  return out;
}
