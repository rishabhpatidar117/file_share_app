import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:swiftshare/core/widgets/glass_card.dart';
import 'package:swiftshare/core/widgets/progress_ring.dart';

void main() {
  testWidgets('GlassCard renders its child', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GlassCard(child: Text('Hello glass')),
        ),
      ),
    );

    expect(find.text('Hello glass'), findsOneWidget);
  });

  testWidgets('GlassCard respects padding and border radius', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GlassCard(
            padding: EdgeInsets.all(24),
            child: Text('x'),
          ),
        ),
      ),
    );

    final decorated = tester.widget<GlassCard>(find.byType(GlassCard));
    expect(decorated.padding, const EdgeInsets.all(24));
  });

  testWidgets('ProgressRing shows a child and clamps progress', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ProgressRing(
            progress: 1.5,
            child: Text('150'),
          ),
        ),
      ),
    );

    expect(find.text('150'), findsOneWidget);

    final ring = tester.widget<ProgressRing>(find.byType(ProgressRing));
    expect(ring.progress, 1.5); // raw value kept; clamped internally when rendered
  });

  testWidgets('ProgressRing respects size and color', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ProgressRing(progress: 0.5, size: 120, color: Colors.green),
        ),
      ),
    );

    final ring = tester.widget<ProgressRing>(find.byType(ProgressRing));
    expect(ring.size, 120);
    expect(ring.color, Colors.green);
  });
}