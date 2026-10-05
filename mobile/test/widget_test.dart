// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:home_poc/map/map_view.dart';

void main() {
  testWidgets('map screen renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MapView())));
    await tester.pumpAndSettle();

    expect(find.text('Search here'), findsOneWidget);

    await tester.tap(find.text('Bedroom 2'));
    await tester.pumpAndSettle();

    expect(find.text('Choose starting point'), findsOneWidget);
  });
}
