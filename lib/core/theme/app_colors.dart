import 'package:flutter/material.dart';

class AppColors {
  AppColors._();

  static const Color primary = Color(0xFF7C4DFF);
  static const Color primaryLight = Color(0xFFB388FF);
  static const Color accent = Color(0xFF7C4DFF);
  
  static const Color lightBackground = Color(0xFFF7F6FB);
  static const Color darkBackground = Color(0xFF14101F);
  
  static const Color glassWhite = Color(0x1AFFFFFF);
  static const Color glassBorder = Color(0x33FFFFFF);
  static const Color glassWhiteDarker = Color(0x33FFFFFF);
  
  static const Color darkGlassWhite = Color(0x0DFFFFFF);
  static const Color darkGlassBorder = Color(0x1AFFFFFF);
  
  static const Color textPrimary = Color(0xFF1A1A2E);
  static const Color textSecondary = Color(0xFF6B7280);
  static const Color textOnPrimary = Color(0xFFFFFFFF);
  
  static const Color darkTextPrimary = Color(0xFFF1F1F6);
  static const Color darkTextSecondary = Color(0xFF9CA3AF);
  
  static const Color success = Color(0xFF10B981);
  static const Color error = Color(0xFFEF4444);
  static const Color warning = Color(0xFFF59E0B);
  
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primary, primaryLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  
  static const LinearGradient backgroundGradientLight = LinearGradient(
    colors: [lightBackground, Color(0xFFF0ECFF)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
  
  static const LinearGradient backgroundGradientDark = LinearGradient(
    colors: [darkBackground, Color(0xFF1E1432)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}