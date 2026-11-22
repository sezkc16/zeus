import 'package:flutter/widgets.dart';

import '../../../../core/network/clearance/resolve_diagnostic.dart';

/// The last WebView resolve's diagnostic, on the "No streams found"
/// screen (b124): one small line the user can screenshot and send
/// back, so a resolve that ends with nothing finally says where it
/// stopped. Shown only while the reading is fresh (ended within a
/// minute) — an older title's reading never explains a newer failure —
/// and nothing at all when no resolve has run.
class ResolveDiagnosticText extends StatelessWidget {
  const ResolveDiagnosticText({super.key});

  @override
  Widget build(BuildContext context) {
    final diagnostic = ResolveDiagnostic.last;
    if (diagnostic == null || !diagnostic.freshAt(DateTime.now())) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        diagnostic.summary,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Color(0x8AFFFFFF), fontSize: 12),
      ),
    );
  }
}
