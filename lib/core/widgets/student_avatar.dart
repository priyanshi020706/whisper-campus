import 'package:flutter/material.dart';

class StudentAvatar extends StatelessWidget {
  const StudentAvatar({super.key, required this.seed, this.size = 36});

  final String? seed;
  final double size;

  static const _choices = <String, (String, int)>{
    '8E6CFF': ('🤖', 0xFF8E6CFF),
    '4CC9F0': ('👾', 0xFF4CC9F0),
    'FF8A65': ('🧑‍🚀', 0xFFFF8A65),
    'F5B942': ('🛸', 0xFFF5B942),
    'F06292': ('🐱', 0xFFF06292),
    '4CAF87': ('🐸', 0xFF4CAF87),
    '7389FF': ('🐙', 0xFF7389FF),
    'A46FE0': ('🪐', 0xFFA46FE0),
  };

  @override
  Widget build(BuildContext context) {
    // Profiles created before avatar selection was added may have no seed.
    // Keep those users on the same branded default avatar instead of a person
    // placeholder, while still honoring every saved choice.
    final value = _choices[seed?.trim().toUpperCase()] ?? _choices['8E6CFF']!;
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: Color(value.$2),
      child: Text(value.$1, style: TextStyle(fontSize: size * .55)),
    );
  }
}
