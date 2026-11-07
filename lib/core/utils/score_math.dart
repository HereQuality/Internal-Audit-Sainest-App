/// core/utils/score_math.dart
/// ────────────────────────────
/// The one rule for turning scores into a percentage — a mirror of the server's
/// server/utils/scoring.js#percentFrom.
///
/// Scores are never SHOWN with decimals, so an audit's `achieved` / `maxPossible`
/// are whole numbers. But adding up ROUNDED numbers gives wrong totals: a weighted
/// audit of two checkpoints (weight 3 at full marks, weight 1 at half) is exactly
/// 3.5 out of 4 = 87.5%, stored as "4 of 4"; three of them added up as rounded
/// numbers are 12 of 12 = 100%, not 87.5%. So every score also carries its EXACT
/// totals (`achievedExact` / `maxPossibleExact`, never shown, only added up), and
/// anything that combines scores adds up THOSE (falling back to the whole numbers
/// for an audit saved before they existed) and rounds only the final percentage,
/// once, here.
///
/// Null when there is nothing possible to score against (never 0%, never 100%).
int? percentFrom(num achieved, num maxPossible) =>
    maxPossible > 0 ? (achieved / maxPossible * 100).round() : null;
