import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moncommerce/main.dart';

void main() {
  testWidgets('affiche le tableau de bord MonCommerce', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          shopName: 'Boutique Wendé',
          isSuperAdmin: false,
          onLogout: () async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Bonjour, Boutique Wendé'), findsOneWidget);
    expect(find.text('Actions rapides'), findsOneWidget);
    expect(find.text('Vendre'), findsOneWidget);
  });

  testWidgets('affiche la connexion sans session active', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LoginPage(onLogin: (_, _, _) async {})),
    );
    await tester.pumpAndSettle();

    expect(find.text('MonCommerce'), findsOneWidget);
    expect(find.text('Accéder à ma boutique'), findsOneWidget);
  });
}
