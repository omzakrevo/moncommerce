import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:moncommerce/shop_sync.dart';

class MemoryRemote implements ShopSyncRemote {
  ShopSnapshot? snapshot;
  int writes = 0;
  bool racing = false;
  @override
  Future<ShopSnapshot?> read() async => snapshot;
  @override
  Future<int> write(Map<String, dynamic> data, int expectedRevision) async {
    if (racing || (snapshot?.revision ?? 0) != expectedRevision)
      throw const ShopSyncConflict();
    writes++;
    snapshot = ShopSnapshot(
      expectedRevision + 1,
      jsonDecode(jsonEncode(data)) as Map<String, dynamic>,
    );
    return snapshot!.revision;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'nouvel appareil récupère les données sans envoyer sa liste vide',
    () async {
      final remote = MemoryRemote()
        ..snapshot = const ShopSnapshot(4, {
          'products': [
            {'name': 'Riz', 'stock': 12},
          ],
          'sales': [],
        });
      final sync = ShopSync(
        'owner',
        remote,
        await SharedPreferences.getInstance(),
      );
      final result = await sync.synchronize({
        'products': [],
        'sales': [],
      }, hasLocalData: false);
      expect((result['products'] as List).single['name'], 'Riz');
      expect(remote.writes, 0);
    },
  );
  test(
    'premier appareil publie puis retrouve les modifications du second',
    () async {
      final remote = MemoryRemote();
      final sync = ShopSync(
        'owner',
        remote,
        await SharedPreferences.getInstance(),
      );
      final local = {
        'products': [
          {'name': 'Riz', 'stock': 12},
        ],
      };
      await sync.synchronize(local, hasLocalData: true);
      expect(remote.snapshot!.revision, 1);
      remote.snapshot = const ShopSnapshot(2, {
        'products': [
          {'name': 'Riz', 'stock': 10},
        ],
      });
      final result = await sync.synchronize(local, hasLocalData: true);
      expect((result['products'] as List).single['stock'], 10);
      expect(remote.writes, 1);
    },
  );
  test('conflit conserve les deux versions sans écraser les ventes', () async {
    final remote = MemoryRemote();
    final prefs = await SharedPreferences.getInstance();
    final sync = ShopSync('owner', remote, prefs);
    await sync.synchronize({'stock': 10}, hasLocalData: true);
    remote.snapshot = const ShopSnapshot(2, {'stock': 8});
    await expectLater(
      sync.synchronize({'stock': 9}, hasLocalData: true),
      throwsA(isA<ShopSyncConflict>()),
    );
    expect(remote.snapshot!.data['stock'], 8);
    expect(prefs.getString('shop_sync_remote_backup_owner'), isNotNull);
    expect(prefs.getInt(sync.revisionKey), 1);
  });
  test('écriture concurrente rejetée sans avancer la version locale', () async {
    final remote = MemoryRemote()..racing = true;
    final prefs = await SharedPreferences.getInstance();
    final sync = ShopSync('owner', remote, prefs);
    await expectLater(
      sync.synchronize({
        'products': [
          {'name': 'Riz'},
        ],
      }, hasLocalData: true),
      throwsA(isA<ShopSyncConflict>()),
    );
    expect(prefs.getInt(sync.revisionKey), isNull);
  });
  test('comparaison JSON indépendante de l’ordre des clés', () {
    expect(
      canonicalShopData({'a': 1, 'b': 2}),
      canonicalShopData({'b': 2, 'a': 1}),
    );
  });
  test('appareil vide ne crée pas une boutique cloud vide', () async {
    final remote = MemoryRemote();
    final sync = ShopSync(
      'owner',
      remote,
      await SharedPreferences.getInstance(),
    );
    await sync.synchronize({
      'products': [],
      'sales': [],
      'revenue': 0,
      'settings': {},
    }, hasLocalData: true);
    expect(remote.writes, 0);
    expect(remote.snapshot, isNull);
  });
  test('réception différée ne valide pas une version non appliquée', () async {
    final remote = MemoryRemote()
      ..snapshot = const ShopSnapshot(4, {'stock': 12});
    final prefs = await SharedPreferences.getInstance();
    final sync = ShopSync('owner', remote, prefs);
    final data = await sync.synchronize(
      {},
      hasLocalData: false,
      remember: false,
    );
    expect(prefs.getInt(sync.revisionKey), isNull);
    await sync.commit(data);
    expect(prefs.getInt(sync.revisionKey), 4);
  });
}
