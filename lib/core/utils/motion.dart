import 'package:flutter/animation.dart';

/// The app's motion timings, in one place so they are one line to tune.
/// (1.0.1: the report was "animation bohot fast hein" — pages, tabs, the
/// Plugins slide and the segmented pill all felt abrupt.)
///
/// Reduced motion is the caller's job: each user of these checks
/// `MediaQuery.disableAnimationsOf` and jumps instead.

/// A pushed or popped page (details, Settings sub-screens, …).
const Duration kMotionPage = Duration(milliseconds: 360);
const Curve kMotionPageCurve = Curves.easeInOutCubic;

/// Switching bottom tabs: a cross-fade, the new tab settling in from a
/// little to the right. (Opening / closing Settings from the gear is a
/// page: it uses [kMotionPage] and [kMotionSettingsOffset].)
const Duration kMotionTab = Duration(milliseconds: 320);
const Curve kMotionTabCurve = Curves.easeOutCubic;

/// How far (fraction of the width) the incoming tab slides in from.
const double kMotionTabOffset = 0.04;

/// How far (fraction of the width) Settings slides in from / out to.
const double kMotionSettingsOffset = 0.30;

/// The Plugins tab's Installed / Add Plugins slide and its highlight.
const Duration kMotionSegmentPage = Duration(milliseconds: 360);
const Curve kMotionSegmentPageCurve = Curves.easeInOutCubic;

/// The pill of a segmented control (App Theme, Player Engine, PiP).
const Duration kMotionPill = Duration(milliseconds: 280);
const Curve kMotionPillCurve = Curves.easeOutCubic;
