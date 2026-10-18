import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moncommerce/main.dart';

void main() {
  testWidgets('connexion sans nom de boutique, inscription explicite', (
    tester,
  ) async {
    var signedIn = 0;
    var registered = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: LoginPage(
          onLogin: (shop, email, password) async {
            expect(shop, '');
            signedIn++;
          },
          onRegister: (shop, email, password) async {
            registered++;
          },
        ),
      ),
    );
    expect(find.text('Nom de la boutique'), findsNothing);
    await tester.enterText(
      find.byType(TextField).at(0),
      'proprietaire@example.com',
    );
    await tester.enterText(find.byType(TextField).at(1), 'password123');
    await tester.ensureVisible(find.text('Accéder à ma boutique'));
    await tester.tap(find.text('Accéder à ma boutique'));
    await tester.pumpAndSettle();
    expect(signedIn, 1);
    expect(registered, 0);
    await tester.ensureVisible(
      find.text('Première utilisation : créer un compte'),
    );
    await tester.tap(find.text('Première utilisation : créer un compte'));
    await tester.pumpAndSettle();
    expect(find.text('Nom de la boutique'), findsOneWidget);
  });
}
