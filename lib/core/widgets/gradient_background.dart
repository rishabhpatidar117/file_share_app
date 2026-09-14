import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class GradientBackground extends StatelessWidget {
  final Widget child;

  const GradientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        gradient: isDark
            ? AppColors.backgroundGradientDark
            : AppColors.backgroundGradientLight,
      ),
      child: Stack(
        children: [
          Positioned(
            top: -100,
            right: -50,
            child: _Blob(
              color: AppColors.primary.withValues(alpha: isDark ? 0.08 : 0.12),
              size: 300,
            ),
          ),
          Positioned(
            bottom: -80,
            left: -60,
            child: _Blob(
              color: AppColors.primaryLight.withValues(alpha: isDark ? 0.06 : 0.1),
              size: 250,
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).size.height * 0.4,
            left: MediaQuery.of(context).size.width * 0.3,
            child: _Blob(
              color: AppColors.primary.withValues(alpha: isDark ? 0.04 : 0.06),
              size: 200,
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  final Color color;
  final double size;

  const _Blob({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
          ),
        ),
      ),
    );
  }
}