import 'package:flutter/material.dart';

/// `#c25430` / `c25430` / `#ffc25430` → [Color]；解析不了返回 null。
Color? hexColor(String? hex) {
  if (hex == null) return null;
  var s = hex.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length == 6) s = 'ff$s';
  if (s.length != 8) return null;
  final value = int.tryParse(s, radix: 16);
  return value == null ? null : Color(value);
}

/// [Color] → `#rrggbb`，写回服务端用。
String colorHex(Color color) {
  int channel(double v) => (v * 255).round().clamp(0, 255);
  final r = channel(color.r).toRadixString(16).padLeft(2, '0');
  final g = channel(color.g).toRadixString(16).padLeft(2, '0');
  final b = channel(color.b).toRadixString(16).padLeft(2, '0');
  return '#$r$g$b';
}
