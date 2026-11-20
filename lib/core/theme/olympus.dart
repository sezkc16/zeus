/// Olympus Noir — the gold-and-obsidian cinematic identity.
///
/// These are the fixed signature colours of the Olympus Noir design
/// (build 102): the deep obsidian background, the metallic gold accent,
/// the jade secondary. They are design constants, not the user's
/// accent — the accent picker still drives `colorScheme.primary`
/// everywhere else in the app, but the Olympus surfaces (featured hero,
/// floating dock, theme cards, Continue Watching gold bar) wear this
/// exact gold so the look matches the approved mockup whichever accent
/// the user picked.
library;

import 'package:flutter/material.dart';

/// Metallic gold — the Olympus Noir accent (#E7BE63).
const Color kOlympusGold = Color(0xFFE7BE63);

/// Jade — the Olympus Noir secondary accent (#80EAC7).
const Color kOlympusJade = Color(0xFF80EAC7);

/// Obsidian background (#090B10).
const Color kOlympusBackground = Color(0xFF090B10);

/// Obsidian surface (#15171E).
const Color kOlympusSurface = Color(0xFF15171E);

/// Warm off-white text (#F5F3ED).
const Color kOlympusText = Color(0xFFF5F3ED);

/// Muted secondary text (#A5A7AF).
const Color kOlympusTextSecondary = Color(0xFFA5A7AF);
