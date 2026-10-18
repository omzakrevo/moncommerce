import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moncommerce/local_staff.dart';
import 'package:moncommerce/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String fixture;
  late LocalStaffAccount cashier;
  final store = LocalStaffStore();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    cashier = await store.save(
      shopId: 'shop-a',
      shopName: 'Boutique A',
      name: 'Awa',
      login: 'awa',
      role: 'Caissier',
      active: true,
      password: 'secret123',
    );
    fixture = (await SharedPreferences.getInstance()).getString(
      LocalStaffStore.storageKey,
    )!;
  });
  setUp(
    () => SharedPreferences.setMockInitialValues({
      LocalStaffStore.storageKey: fixture,
    }),
  );

  test(
    'authentification locale, mot de passe haché et boutique partagée',
    () async {
      expect(fixture, isNot(contains('secret123')));
      expect(cashier.passwordHash, isNotEmpty);
      final logged = await store.authenticate(' AWA ', 'secret123');
      expect(logged.shopId, 'shop-a');
      expect(logged.canManageUsers, isFalse);
      expect(logged.canManageStock, isFalse);
      await expectLater(
        store.authenticate('awa', 'incorrect'),
        throwsStateError,
      );
    },
  );
  test(
    'désactivation, identifiants uniques et protection entre boutiques',
    () async {
      await expectLater(
        store.save(
          shopId: 'shop-b',
          shopName: 'B',
          name: 'Autre',
          login: 'awa',
          role: 'Caissier',
          active: true,
          password: 'secret123',
        ),
        throwsStateError,
      );
      await expectLater(
        store.save(
          id: cashier.id,
          shopId: 'shop-b',
          shopName: 'B',
          name: 'Awa',
          login: 'awa',
          role: 'Caissier',
          active: true,
        ),
        throwsStateError,
      );
      await store.save(
        id: cashier.id,
        shopId: 'shop-a',
        shopName: 'Boutique A',
        name: 'Awa',
        login: 'awa',
        role: 'Caissier',
        active: false,
      );
      await expectLater(
        store.authenticate('awa', 'secret123'),
        throwsStateError,
      );
      expect(await store.forShop('shop-b'), isEmpty);
    },
  );
  test('réinitialisation du mot de passe et suppression', () async {
    final changed = await store.save(
      id: cashier.id,
      shopId: 'shop-a',
      shopName: 'Boutique A',
      name: 'Awa',
      login: 'awa',
      role: 'Caissier',
      active: true,
      password: 'nouveau123',
    );
    expect(changed.salt, isNot(cashier.salt));
    await expectLater(store.authenticate('awa', 'secret123'), throwsStateError);
    expect((await store.authenticate('awa', 'nouveau123')).id, cashier.id);
    await store.delete('shop-a', cashier.id);
    await expectLater(
      store.authenticate('awa', 'nouveau123'),
      throwsStateError,
    );
  });
  test('anciennes fiches conservées mais sans connexion implicite', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'users_v1',
      jsonEncode([
        {'name': 'Ancien', 'detail': 'Gestionnaire', 'active': 'true'},
      ]),
    );
    await store.importLegacy('shop-a', 'Boutique A');
    await store.importLegacy('shop-b', 'Boutique B');
    final migrated = (await store.forShop(
      'shop-a',
    )).singleWhere((a) => a.name == 'Ancien');
    expect(migrated.active, isFalse);
    expect(migrated.configured, isFalse);
    expect(await store.forShop('shop-b'), isEmpty);
  });
  test('limiter les tentatives répétées', () async {
    for (var i = 0; i < 5; i++) {
      await expectLater(
        store.authenticate('introuvable', 'incorrect'),
        throwsStateError,
      );
    }
    await expectLater(
      store.authenticate('introuvable', 'incorrect'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('30 secondes'),
        ),
      ),
    );
  });

  testWidgets(
    'connexion et vente caissier sans session réseau ni accès administrateur',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(localStaffLoginRequiredKey, true);
      await prefs.setBool('is_super_admin_v1', true);
      await prefs.setBool('offline_access_granted_v1', true);
      await prefs.setString('offline_access_user_id_v1', 'other-shop');
      await prefs.setString(
        'moncommerce_data_v2_shop-a',
        jsonEncode({
          'revenue': 0,
          'expenses': 0,
          'salesCount': 0,
          'products': [
            Product(
              'Savon',
              750,
              5,
              Icons.inventory,
              barcode: '00123',
            ).toJson(),
          ],
          'credits': [],
          'sales': [],
          'expenseRecords': [],
        }),
      );
      await tester.pumpWidget(const MaterialApp(home: AuthGate()));
      await tester.pumpAndSettle();
      expect(find.text('Se connecter hors ligne'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Identifiant de connexion'),
        'awa',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Mot de passe'),
        'secret123',
      );
      await tester.tap(find.text('Se connecter hors ligne'));
      for (
        var i = 0;
        i < 200 && find.byType(AppShell).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      final shell = tester.widget<AppShell>(find.byType(AppShell));
      expect(shell.storageUserId, 'shop-a');
      expect(shell.isSuperAdmin, isFalse);
      expect(shell.offlineMode, isTrue);
      expect(find.text('Utilisateurs'), findsNothing);
      expect(find.text('Produits'), findsNothing);
      await tester.tap(find.text('Nouvelle vente'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Lecteur de code-barres USB'),
        '00123',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Panier (1)'), findsOneWidget);
      await tester.tap(find.text('Valider la vente'));
      await tester.pumpAndSettle();
      final saved =
          jsonDecode(prefs.getString('moncommerce_data_v2_shop-a')!) as Map;
      expect(saved['salesCount'], 1);
      expect(saved['sales'][0]['operatorId'], cashier.id);
      expect(saved['sales'][0]['operatorName'], 'Awa');
      expect(find.text('Panier (0)'), findsOneWidget);
      await tester.tap(find.byTooltip('Fermer la vente'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Déconnexion'));
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      // Restart still requests credentials, even with old owner credentials cached.
      await tester.pumpWidget(
        const MaterialApp(home: AuthGate(key: ValueKey('restart'))),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(AppShell), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
