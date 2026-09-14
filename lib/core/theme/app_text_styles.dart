import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

class AppTextStyles {
  AppTextStyles._();

  static TextStyle _base({required bool isDark}) => GoogleFonts.inter(
    color: isDark ? AppColors.darkTextPrimary : AppColors.textPrimary,
  );

  static TextStyle heading1({bool isDark = false}) =>
    _base(isDark: isDark).copyWith(fontSize: 28, fontWeight: FontWeight.w700);

  static TextStyle heading2({bool isDark = false}) =>
    _base(isDark: isDark).copyWith(fontSize: 22, fontWeight: FontWeight.w600);

  static TextStyle heading3({bool isDark = false}) =>
    _base(isDark: isDark).copyWith(fontSize: 18, fontWeight: FontWeight.w600);

  static TextStyle body({bool isDark = false}) =>
    _base(isDark: isDark).copyWith(fontSize: 15, fontWeight: FontWeight.w400);

  static TextStyle bodySmall({bool isDark = false}) =>
    _base(isDark: isDark).copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary,
    );

  static TextStyle label({bool isDark = false}) =>
    _base(isDark: isDark).copyWith(fontSize: 12, fontWeight: FontWeight.w500);

  static TextStyle buttonText() => GoogleFonts.inter(
    color: AppColors.textOnPrimary,
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );
}