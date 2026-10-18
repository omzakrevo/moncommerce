import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:moncommerce/shop_account.dart';

void main() {
  test('la boutique existante est retrouvée sans aucune écriture', () async {
    final client = SupabaseClient(
      'https://example.supabase.co',
      'test',
      httpClient: MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.queryParameters['id'], 'eq.owner-id');
        return http.Response(
          jsonEncode({'shop_name': 'Ma première boutique'}),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final service = ShopAccountService(client);
    expect(
      await service.configure('owner-id', 'Nouveau nom accidentel'),
      'Ma première boutique',
    );
    await client.dispose();
  });
  test(
    'création concurrente ne remplace pas le nom gagné sur un autre appareil',
    () async {
      var reads = 0;
      final client = SupabaseClient(
        'https://example.supabase.co',
        'test',
        httpClient: MockClient((request) async {
          if (request.method == 'GET') {
            reads++;
            return http.Response(
              reads == 1 ? 'null' : '{"shop_name":"Boutique déjà créée"}',
              200,
              request: request,
              headers: {'content-type': 'application/json'},
            );
          }
          expect(request.method, 'POST');
          expect(
            request.headers['Prefer'],
            contains('resolution=ignore-duplicates'),
          );
          expect(jsonDecode(request.body)['id'], 'owner-id');
          return http.Response('', 201, request: request);
        }),
      );
      expect(
        await ShopAccountService(client).configure('owner-id', 'Autre nom'),
        'Boutique déjà créée',
      );
      await client.dispose();
    },
  );
}
