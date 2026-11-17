import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import '../utils/motion.dart';

/// The app's page transition (ZoroX v4): every full-screen navigation
/// glides in with the same slide + fade instead of snapping open. The
/// report was the Settings gear ("jhatak se nahi, thoda majese khulna
/// chaiye"), and the same motion is used for detail, the player and the
/// rest, so the app feels of a piece.
///
/// [kMotionPage] with [kMotionPageCurve] (1.0.1: 300 ms felt too fast). The incoming page slides
/// in from a little to the right (8% of the width) while fading in;
/// popping reverses it. A small slide, not the platform default's
/// full-width one: it reads as a glide rather than a shove.
///
/// Used by the pushed routes' buildPage overrides (see app_router.dart).
/// Branch switches (tabs, the Settings gear) are a different mechanism —
/// the shell swaps branch Navigators instantly, so they get the same
/// motion from the shell itself (see AppScaffold).
///
/// On iOS (1.0.1) a pushed page is a [CupertinoPage] instead: the native
/// slide, and with it the swipe from the left edge to go back, which
/// follows the finger and cancels when let go early. The custom transition
/// above is a [PageRouteBuilder], which has no back gesture. [swipeBack]
/// false keeps the custom transition on iOS too — the player uses it, so
/// its own horizontal gestures are never taken for a back swipe.
Page<void> smoothPage({
  required LocalKey key,
  required Widget child,
  bool swipeBack = true,
}) {
  if (swipeBack && defaultTargetPlatform == TargetPlatform.iOS) {
    return CupertinoPage<void>(key: key, child: child);
  }
  return CustomTransitionPage<void>(
    key: key,
    child: child,
    transitionDuration: kMotionPage,
    reverseTransitionDuration: kMotionPage,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: kMotionPageCurve,
      );
      return SlideTransition(
        position:
            Tween<Offset>(
              begin: const Offset(0.08, 0),
              end: Offset.zero,
            ).animate(curved),
        child: FadeTransition(opacity: curved, child: child),
      );
    },
  );
}
